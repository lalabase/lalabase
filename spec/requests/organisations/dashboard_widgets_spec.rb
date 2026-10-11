# frozen_string_literal: true

require 'rails_helper'

# What:  Organisations::DashboardWidgetsController#show — single-widget Turbo refresh that powers the
#        live in-widget search of the project dashboard's recent_tickets widget.
# Type:  Request spec (full stack: auth, widget whitelist, the component's tickets:read gate, the
#        real TicketSearchQuery, and project/tenant scoping of the results).
# Why:   The endpoint renders a widget out of band, so it must enforce the SAME gate as the dashboard
#        (tickets read), reject unknown widgets, search ALL of the project's tickets like the list page,
#        and never leak another project's tickets into the frame.
RSpec.describe 'Organisations::DashboardWidgets', type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:member) { create(:user) }

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') }
  end

  # A sibling project the member has NO permission on — used for the tickets:read gate (403).
  let!(:project_no_access) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') }
  end

  let!(:member_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: member, project: project, tickets_access: 'read_only')
    end
  end

  let(:frame_id) { "recent_tickets_widget_#{project.id}" }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'GET #show' do
    it 'renders the recent_tickets frame, layout-free' do
      sign_in member
      get organisation_project_dashboard_widget_path(organisation, project, 'recent_tickets')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="#{frame_id}"))
      expect(response.body).not_to include('<html') # fragment only, no app chrome
    end

    it 'searches ALL of the project tickets (same engine as the list page) and shows only the matches' do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, title: 'Quokka Treffer')
        create(:ticket, project: project, organisation: organisation, title: 'Wombat daneben')
      end

      sign_in member
      get organisation_project_dashboard_widget_path(organisation, project, 'recent_tickets', q: 'Quokka')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Quokka Treffer')
      expect(response.body).not_to include('Wombat daneben')
    end

    it 'never leaks tickets from another project into the frame' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, title: 'Quokka hier')
        create(:ticket, project: other_project, organisation: organisation, title: 'Quokka woanders')
      end

      sign_in member
      get organisation_project_dashboard_widget_path(organisation, project, 'recent_tickets', q: 'Quokka')

      expect(response.body).to include('Quokka hier')
      expect(response.body).not_to include('Quokka woanders')
    end

    it 'returns 404 for an unknown widget key' do
      sign_in member
      get organisation_project_dashboard_widget_path(organisation, project, 'recent_notes')

      expect(response).to have_http_status(:not_found)
    end

    it 'forbids a viewer without tickets:read on the project' do
      sign_in member
      get organisation_project_dashboard_widget_path(organisation, project_no_access, 'recent_tickets', q: 'Quokka')

      expect(response).to have_http_status(:forbidden)
    end

    it 'redirects an unauthenticated user to sign in' do
      get organisation_project_dashboard_widget_path(organisation, project, 'recent_tickets')

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
