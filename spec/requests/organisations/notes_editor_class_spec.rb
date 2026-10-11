# frozen_string_literal: true

require 'rails_helper'

# What:  The note editor (and display) must carry the `lexxy-content` class.
# Type:  Request spec (guard).
# Why:   Lexxy's content stylesheet — including the table cell borders — is scoped to
#        :where(.lexxy-content). The form previously passed `prose max-w-none`, which the
#        helper's `class ||= "lexxy-content"` does NOT override, so the editor lost the
#        lexxy-content class and tables rendered without a grid. This guard turns red if
#        the editor stops carrying lexxy-content (e.g. someone reintroduces prose).
RSpec.describe 'Note editor lexxy-content class', type: :request do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "M#{SecureRandom.hex(4)}", is_default: true)
  end
  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:note) { ActsAsTenant.with_tenant(organisation) { create(:note, organisation: organisation, project: project, content: '<div>x</div>') } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  it 'renders the editor with the lexxy-content class (so table cell borders apply)' do
    create(:project_permission, user: member, project: project, notes_access: 'read_write')
    sign_in member

    get edit_organisation_project_note_path(organisation, project, note, format: :turbo_stream)

    expect(response).to have_http_status(:ok)
    # the <lexxy-editor> tag must include lexxy-content in its class list
    expect(response.body).to match(/<lexxy-editor[^>]*\bclass="[^"]*\blexxy-content\b/)
  end
end
