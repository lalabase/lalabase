# frozen_string_literal: true

require 'rails_helper'

# What:  Organisations::MentionsController — the @-mention picker behind Lexxy's
#        <lexxy-prompt src>. Returns an HTML fragment of <lexxy-prompt-item>.
# Type:  Request spec.
# Why:   SECURITY-CRITICAL (Lane B): the picker is the one place a signed sgid for a
#        note/document is minted into the editor. It must mint ONLY for records the
#        current user may read — policy_scope is the gate. A leak here would let a user
#        link to (and, on render, reveal the title of) content from a project/org they
#        cannot access. So the core tests are negative: no item, no sgid for the unreachable.
RSpec.describe 'Organisations::Mentions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:project)       { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(user, proj, **areas)
    create(:project_permission, { user: user, project: proj }.merge(areas))
  end

  def get_mentions(proj, filter: nil)
    get organisation_project_mentions_path(organisation, proj, filter: filter)
  end

  # A Document's title lives on its current_version, so build one explicitly (factory has none).
  def create_document(title:)
    ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, organisation: organisation, project: project)
      version = create(:document_version, document: doc, organisation: organisation, title: title)
      doc.update!(current_version: version)
      doc
    end
  end

  describe 'GET index (accessible)' do
    it 'returns matching notes as prompt items carrying the server-minted sgid' do
      grant(member, project, notes_access: 'read_only')
      note = ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project, title: 'Alpha Spec') }
      sign_in member

      get_mentions(project, filter: 'Alph')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Alpha Spec')
      # the sgid is minted server-side onto the prompt item (Lexxy reads it from there),
      # never supplied by the client; content-type is set client-side from the prompt name.
      expect(response.body).to include(%(<lexxy-prompt-item))
      expect(response.body).to include(%(sgid="#{note.attachable_sgid}"))
      # the inserted chip is a styled reference, not plain text: wiki-mention + a note icon
      expect(response.body).to include('wiki-mention')
      expect(response.body).to include('bi-journal-text')
    end

    it 'filters by title (a non-matching note is absent)' do
      grant(member, project, notes_access: 'read_only')
      ActsAsTenant.with_tenant(organisation) do
        create(:note, organisation: organisation, project: project, title: 'Findable')
        create(:note, organisation: organisation, project: project, title: 'Hidden By Filter')
      end
      sign_in member

      get_mentions(project, filter: 'Findable')

      expect(response.body).to include('Findable')
      expect(response.body).not_to include('Hidden By Filter')
    end
  end

  describe 'SECURITY — no leak of unreachable records' do
    it 'returns no note items when the user has no notes access in the project' do
      grant(member, project, notes_access: 'no_access')
      ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project, title: 'Secret Note') }
      sign_in member

      get_mentions(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Secret Note')
      expect(response.body).not_to include('<lexxy-prompt-item')
    end

    it 'does not leak notes from a sibling project the user cannot access (no item, no sgid)' do
      grant(member, project, notes_access: 'read_only') # access to THIS project only
      foreign = ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: other_project, title: 'Foreign Note') }
      sign_in member

      # query the project the user cannot read notes in
      get_mentions(other_project, filter: 'Foreign')

      expect(response.body).not_to include('Foreign Note')
      expect(response.body).not_to include(foreign.attachable_sgid)
    end

    it 'requires authentication' do
      get_mentions(project)
      expect(response).to redirect_to(new_user_session_path)
    end

    # Mutation guard for `.where(project: @project)` (the Lane B "mentions are project-local"
    # decision). The other leak test uses a user WITHOUT access to the sibling project, so
    # policy_scope alone hides it — dropping the project filter would NOT turn it red. Here
    # the user CAN read both projects, so only the project filter keeps the sibling out.
    it 'is scoped to the queried project even when the user can read sibling projects' do
      grant(member, project, notes_access: 'read_only')
      grant(member, other_project, notes_access: 'read_only')
      ActsAsTenant.with_tenant(organisation) do
        create(:note, organisation: organisation, project: project, title: 'Here Note')
        create(:note, organisation: organisation, project: other_project, title: 'Elsewhere Note')
      end
      sign_in member

      get_mentions(project)

      expect(response.body).to include('Here Note')
      expect(response.body).not_to include('Elsewhere Note')
    end

    # Mutation guard for sanitize_sql_like: a raw "%" would match every title if not escaped.
    it 'escapes LIKE wildcards so "%" matches literally (not everything)' do
      grant(member, project, notes_access: 'read_only')
      ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project, title: 'Plain Note') }
      sign_in member

      get_mentions(project, filter: '%')

      expect(response.body).not_to include('Plain Note')
      expect(response.body).not_to include('<lexxy-prompt-item')
    end
  end

  describe 'query efficiency' do
    # Mutation guard for the includes() in mention_candidates: spec/support/prosopite.rb
    # scans every example, so an N+1 (project/organisation per row, document.title →
    # current_version per row) raises here. Setup is paused so only the GET is scanned.
    it 'avoids an N+1 across several notes and documents' do
      grant(member, project, notes_access: 'read_only', documents_access: 'read_only')
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          3.times { |i| create(:note, organisation: organisation, project: project, title: "EffNote #{i}") }
        end
        3.times { |i| create_document(title: "EffDoc #{i}") }
      end
      sign_in member

      get_mentions(project)

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('<lexxy-prompt-item').size).to eq(6)
    end
  end

  describe 'result cap' do
    # Mutation guard for MAX_RESULTS: without any cap, all matches would flood the dropdown.
    it 'returns at most MAX_RESULTS items' do
      grant(member, project, notes_access: 'read_only')
      cap = Organisations::MentionsController::MAX_RESULTS
      ActsAsTenant.with_tenant(organisation) do
        (cap + 2).times { |i| create(:note, organisation: organisation, project: project, title: "Capped #{i}") }
      end
      sign_in member

      get_mentions(project, filter: 'Capped')

      expect(response.body.scan('<lexxy-prompt-item').size).to eq(cap)
    end
  end

  describe 'documents' do
    it 'returns accessible documents and respects documents_access' do
      grant(member, project, documents_access: 'read_only')
      create_document(title: 'Doc Mention')
      sign_in member

      get_mentions(project, filter: 'Doc Mention')

      expect(response.body).to include('Doc Mention')
      # document references render with the document icon (distinct from notes)
      expect(response.body).to include('bi-file-earmark-text')
    end

    it 'returns no document items without documents access' do
      grant(member, project, documents_access: 'no_access')
      create_document(title: 'Blocked Doc')
      sign_in member

      get_mentions(project, filter: 'Blocked Doc')

      expect(response.body).not_to include('Blocked Doc')
    end
  end
end
