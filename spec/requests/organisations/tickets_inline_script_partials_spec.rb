# frozen_string_literal: true

# What: Request spec for the CONTROLLER wiring of the former inline-<script> heredocs
#   in tickets#create, now rendered from partials (S4). Since Paket 3 the writing surface
#   is closed by the stream that clears turbo-frame#writing_surface, the scripts no longer touch a
#   modal; both branches must send that clearing stream first.
# Why: proves each create branch still streams the right redirect/highlight script with
#   the interpolated values. The partials' rendered OUTPUT is pinned separately in
#   spec/views/organisations/tickets/inline_script_partials_spec.rb.
# Note: tickets#destroy is request-tested in tickets_destroy_spec.rb. (The
#   "authz quirk" this note used to cite was a real bug: verify_authorized raised
#   after the delete and the browser got a 500.)

require 'rails_helper'

RSpec.describe 'Tickets inline-script partials wiring (S4)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  def last_ticket
    ActsAsTenant.with_tenant(organisation) { project.tickets.order(:created_at).last }
  end

  describe 'POST create from the dashboard' do
    it 'clears the modal frame and streams the redirect script for the created ticket' do
      post organisation_project_tickets_path(organisation, project),
           params: { ticket: { title: 'Dashboard ticket' }, source: 'dashboard' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-stream action="update" target="writing_surface">')
      expect(response.body).not_to include('data-context')
      expect(response.body).to include('window.location.href')
      expect(response.body).to include(organisation_project_tickets_path(organisation, project, ticket_id: last_ticket.id))
    end
  end

  describe 'POST create from the index modal' do
    it 'clears the modal frame and streams the layout + row-highlight script with the new ticket id' do
      post organisation_project_tickets_path(organisation, project),
           params: { ticket: { title: 'Index ticket' }, source: 'index_page' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-stream action="update" target="writing_surface">')
      expect(response.body).not_to include('data-context')
      expect(response.body).to include('show-content')
      expect(response.body).to include(%(const ticketId = "#{last_ticket.id}"))
      expect(response.body).to include('selected-row')
    end
  end
end
