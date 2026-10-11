# frozen_string_literal: true

require 'rails_helper'

# The time list is ONE page for the organisation; a project is a filter on it,
# not a page of its own (doc/zeiten_eine_liste_plan.md). The title stays plain
# "Zeiten" with and without that filter. The old "Projektzeiten" wording was
# the project page's; that page redirects (see time_sessions_project_redirect_spec).
RSpec.describe 'time sessions page title', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  it 'titles the list "Zeiten"' do
    get organisation_time_sessions_path(organisation)

    expect(response.body).to include(I18n.t('views.organisations.time_sessions.index.title_times'))
  end

  it 'keeps that title with a project filter' do
    get organisation_time_sessions_path(organisation, project_id_filter: project.id)

    expect(response.body).to include(I18n.t('views.organisations.time_sessions.index.title_times'))
    expect(response.body).not_to include('Projektzeiten')
  end
end
