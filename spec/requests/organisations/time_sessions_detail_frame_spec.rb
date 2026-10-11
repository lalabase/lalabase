# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Time session detail frame', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:time_session) do
    create(:time_session, organisation: organisation, project: project, creator: user,
                          duration: 30, occurred_on: Time.zone.today, description: 'Detailzeit')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'renders HTML into a caller-provided lane frame' do
    get organisation_project_time_session_path(organisation, project, time_session,
                                               frame: 'content', frame_id: 'ticket_display_frame'),
        headers: { 'Turbo-Frame' => 'ticket_display_frame' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('turbo-frame id="ticket_display_frame"', 'Detailzeit')
  end
end
