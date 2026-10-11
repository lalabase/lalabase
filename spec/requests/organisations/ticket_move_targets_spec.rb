# frozen_string_literal: true

require 'rails_helper'

# Both ways of moving a ticket offer projects of the ticket's own organisation only
# (doc/ticket_relations_plan.md, revision 4, §3.3). Ticket relations rely on it: they may cross
# projects but never organisations, and a move cleans nothing up because the organisation
# cannot change. A user in two organisations is the case that would show a foreign project.
RSpec.describe 'Move targets stay in the organisation', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:second_organisation) { create(:organisation) }
  let(:user) { create(:user) }

  let(:project) { in_org(organisation) { create(:project, organisation: organisation, name: 'Quellprojekt') } }
  let!(:sibling) { in_org(organisation) { create(:project, organisation: organisation, name: 'Schwesterprojekt') } }
  let!(:foreign) do
    in_org(second_organisation) { create(:project, organisation: second_organisation, name: 'Fremdprojekt') }
  end
  let(:ticket) { in_org(organisation) { create(:ticket, project: project, creator: user, title: 'Moves') } }

  before do
    [organisation, second_organisation].each do |org|
      in_org(org) { create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true) }
    end
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def in_org(org, &)
    ActsAsTenant.with_tenant(org, &)
  end

  it 'offers the single move only projects of the organisation' do
    get move_preflight_organisation_project_ticket_path(organisation, project, ticket)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Schwesterprojekt')
    expect(response.body).not_to include('Fremdprojekt', foreign.id)
  end

  it 'offers the bulk move only projects of the organisation' do
    ticket
    # The panel is a frame of the list: without the header the action sends the page back.
    get bulk_edit_organisation_project_tickets_path(organisation, project), headers: { 'Turbo-Frame' => 'ticket_display_frame' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Schwesterprojekt')
    expect(response.body).not_to include('Fremdprojekt', foreign.id)
  end
end
