# frozen_string_literal: true

require 'rails_helper'

# What: The project's own times page is gone (doc/zeiten_eine_liste_plan.md):
#       it was the organisation list narrowed to one project. Its address must
#       not go with it: the hours chip on a ticket, a bookmark, an old chat
#       answer all still carry it.
# Type: Request spec on the routing. The old GET is a permanent redirect onto
#       the organisation list with the project preselected and every other
#       parameter kept; the POST on the same path (create, used by the ticket
#       and meeting modals) is untouched.
RSpec.describe 'Project times page redirect', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:user)         { create(:user) }
  let(:project)      { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket)       { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }

  let(:old_address) { "/org/#{organisation.id}/projects/#{project.id}/time_sessions" }

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
    sign_in user
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  it 'sends the bare project address to the organisation list with the project preselected' do
    get old_address

    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to(organisation_time_sessions_path(organisation, project_id_filter: project.id))
  end

  # The chip on a ticket carries ticket_id plus the neutralising params. Losing
  # any of them would open the list on a different set than the number promised.
  it 'keeps every parameter of the old link' do
    get old_address, params: { ticket_id: ticket.id, **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS }

    expect(response).to have_http_status(:moved_permanently)
    target = URI.parse(response.location)
    expect(target.path).to eq(organisation_time_sessions_path(organisation))
    query = Rack::Utils.parse_nested_query(target.query)
    expect(query).to include('project_id_filter' => project.id, 'ticket_id' => ticket.id,
                             'date_range' => 'all')
    expect(query['status_filters']).to match_array(TimeSession::BILLING_STATUS_FILTERS)
  end

  it 'lands on a 200 list that received those filters' do
    get old_address, params: { ticket_id: ticket.id, date_range: 'all' }
    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(controller.params[:project_id_filter]).to eq(project.id)
    expect(controller.params[:ticket_id]).to eq(ticket.id)
    expect(controller.params[:date_range]).to eq('all')
  end

  it 'leaves the POST on the same path alone: that is the booking form of the ticket modal' do
    # The request resets the tenant on its way out; count inside one.
    expect do
      post old_address, params: { time_session: { duration_string: '0:30', occurred_on: Date.current.to_s,
                                                  description: 'Noch da' } }
    end.to change { ActsAsTenant.with_tenant(organisation) { TimeSession.count } }.by(1)

    expect(response).not_to have_http_status(:moved_permanently)
  end
end
