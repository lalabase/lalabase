# frozen_string_literal: true

require 'rails_helper'

# What:  WikiMentionsHelper#wiki_mention_readable? — the render-time access gate for a
#        mention chip (F2).
# Type:  Helper spec.
# Why:   Mentions are project-local, but note→document crosses areas. A viewer with
#        notes-read but no documents-read must NOT get a working backlink to a document.
#        This gate is what turns the chip into inert text in that case; it must also fail
#        safe (no link) when there is no user context.
RSpec.describe WikiMentionsHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "M#{SecureRandom.hex(4)}", is_default: true)
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(**areas)
    create(:project_permission, { user: user, project: project }.merge(areas))
  end

  def document_with_title(title)
    ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, organisation: organisation, project: project)
      version = create(:document_version, document: doc, organisation: organisation, title: title)
      doc.update!(current_version: version)
      doc
    end
  end

  describe '#wiki_mention_readable?' do
    it 'fails safe (false) without a current user' do
      allow(helper).to receive(:current_user).and_return(nil)
      note = ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project) }

      expect(helper.wiki_mention_readable?(note)).to be(false)
    end

    it 'is true for a note the viewer can read' do
      grant(notes_access: 'read_only')
      allow(helper).to receive(:current_user).and_return(user)
      note = ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project) }

      expect(helper.wiki_mention_readable?(note)).to be(true)
    end

    # The actual F2 leak vector: a readable note that mentions a document the viewer's
    # area access does not cover.
    it 'is false for a document the viewer cannot read (notes ok, documents denied)' do
      grant(notes_access: 'read_only', documents_access: 'no_access')
      allow(helper).to receive(:current_user).and_return(user)
      doc = document_with_title('Secret Doc')

      expect(helper.wiki_mention_readable?(doc)).to be(false)
    end
  end
end
