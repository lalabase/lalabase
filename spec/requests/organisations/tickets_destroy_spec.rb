# frozen_string_literal: true

# What: Request spec for tickets#destroy, the Turbo Stream branch the delete button in
#   the detail column uses ("Löschen" in _ticket_action_bar).
# Why: Regression guard. The action deleted the record but then crashed in the
#   Pundit after_action (verify_authorized) because the permission check used
#   policy(...).destroy? instead of authorize. Turbo received a 500 HTML page for
#   a frame-targeted submission, found no matching frame and left the edit form
#   standing although the ticket was already gone.

require 'rails_helper'

RSpec.describe 'Tickets destroy', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let!(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user)
  end

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  describe 'DELETE as Turbo Stream (edit form in the detail column)' do
    it 'deletes the ticket and answers with the streams that close the detail column' do
      expect do
        delete organisation_project_ticket_path(organisation, project, ticket), headers: turbo_headers
      end.to change { ActsAsTenant.with_tenant(organisation) { Ticket.exists?(ticket.id) } }.from(true).to(false)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      # Detail frame (desktop + mobile) gets the empty state.
      expect(response.body).to include('action="update" targets="#ticket_display_frame"')
      expect(response.body).to include(I18n.t('flash.tickets.deleted_empty_content_title'))
      # Success notice through the standard flash component (positioned, auto-hide),
      # not a hand-built div.
      expect(response.body).to include('action="update" target="flash"')
      expect(response.body).to include('data-controller="neo-flash"')
      expect(response.body).to include(I18n.t('flash.tickets.deleted_notice'))
      # The list row goes via selector (desktop + mobile), not via a re-rendered list.
      # (Rails escapes the quotes inside the attribute as &#39;.)
      expect(response.body).to include(%(action="remove" targets="tr[data-ticket-id=&#39;#{ticket.id}&#39;], .mobile-ticket-row[data-ticket-id=&#39;#{ticket.id}&#39;]"))
    end
  end

  describe 'DELETE as HTML' do
    it 'deletes the ticket and redirects to the list' do
      delete organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
      expect(ActsAsTenant.with_tenant(organisation) { Ticket.exists?(ticket.id) }).to be(false)
    end
  end

  describe 'DELETE without the delete permission' do
    # A member who may edit tickets in the project (read_write area access) but whose
    # role lacks tickets/delete_tickets: the before_action must keep its friendly
    # redirect and the record must survive.
    let(:editor) { create(:user) }

    before do
      ActsAsTenant.current_tenant = organisation
      member_role = create(:role, organisation: organisation, title: 'editor_without_delete')
      create(:membership, user: editor, organisation: organisation, role: member_role)
      create(:project_permission, user: editor, project: project, tickets_access: 'read_write')
      sign_in editor
    end

    it 'keeps the ticket and redirects with an alert' do
      delete organisation_project_ticket_path(organisation, project, ticket), headers: turbo_headers

      expect(ActsAsTenant.with_tenant(organisation) { Ticket.exists?(ticket.id) }).to be(true)
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
      expect(flash[:alert]).to eq(I18n.t('flash.tickets.no_delete_permission'))
    end
  end
end
