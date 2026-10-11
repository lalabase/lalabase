# frozen_string_literal: true

require 'rails_helper'

# organisations#select is the cross-org cockpit. It runs with NO tenant set
# (skip_before_action :load_tenant_from_session) and require_tenant is true, so a tenanted read
# leaking outside Dashboard::CrossOrgActionSummary would raise NoTenantSet (500). The "renders
# 200" specs are the regression guard for that. Also covers the Phase-1 drop-in degrade.
RSpec.describe 'Organisations#select (cross-org cockpit)', type: :request do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }

  after { ActsAsTenant.current_tenant = nil }

  def admin_member(org)
    role = create(:role, title: 'account_admin', organisation: org)
    create(:membership, user: user, organisation: org, role: role, active: true)
  end

  context 'when not signed in' do
    it 'redirects to the login page' do
      get select_organisation_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'when signed in as a multi-org user with assigned work' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(org_a)
        project = create(:project, organisation: org_a, name: 'Alpha Project')
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                             options: { 'allowed_values' => [
                                               { 'value' => 'open', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] }
                                             ] })
        # Overdue so it qualifies under the DEFAULT 'important' importance level (a plain open ticket
        # would now be filtered out — see the T-CRIT context below).
        t = create(:ticket, project: project, organisation: org_a, title: 'Fix the thing',
                            custom_attributes: { 'status' => 'open', 'due_date' => 2.days.ago.to_date.iso8601 })
        create(:ticket_assignment, ticket: t, user: user)
        t
      end
    end

    before do
      ActsAsTenant.with_tenant(org_b) { admin_member(org_b) }
      ActsAsTenant.current_tenant = nil
      sign_in user
    end

    it 'renders 200 with no tenant set (no NoTenantSet) and shows the action summary' do
      get select_organisation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Fix the thing')
    end

    it 'deep-links each summary row into the org-scoped path' do
      get select_organisation_path

      expect(response.body).to include(organisation_project_ticket_path(org_a, ticket.project, ticket))
    end

    it 'resolves the correct tenant when the deep-link target is requested' do
      get organisation_root_path(org_a)

      expect(response).to have_http_status(:ok)
    end
  end

  context 'personal To-Do roll-up' do
    before do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(org_a)
        create(:personal_task, user: user, organisation: org_a, title: 'Rückruf Kunde X')
      end
      ActsAsTenant.current_tenant = nil
      sign_in user
    end

    it "renders the user's own open personal to-dos on the cockpit" do
      get select_organisation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Rückruf Kunde X')
    end
  end

  context 'single-org user' do
    before do
      ActsAsTenant.with_tenant(org_a) { admin_member(org_a) }
      ActsAsTenant.current_tenant = nil
      sign_in user
    end

    it 'renders 200' do
      get select_organisation_path
      expect(response).to have_http_status(:ok)
    end
  end

  # T-CRIT: the default importance level is 'important', so a plain assigned ticket (not overdue,
  # not high priority) must NOT appear by default but MUST appear once the user picks 'all'. Without
  # both halves the suite could pass while the default filter (or the 'all' level) silently broke.
  describe 'importance level filtering (T-CRIT)' do
    let!(:plain_ticket) do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(org_a)
        project = create(:project, organisation: org_a, name: 'Alpha Project')
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                             options: { 'allowed_values' => [
                                               { 'value' => 'open', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] }
                                             ] })
        t = create(:ticket, project: project, organisation: org_a, title: 'Plain normal ticket',
                            custom_attributes: { 'status' => 'open' }) # no due date, normal priority
        create(:ticket_assignment, ticket: t, user: user)
        t
      end
    end

    before do
      ActsAsTenant.current_tenant = nil
      sign_in user
    end

    it 'hides a plain ticket under the default "important" level' do
      get select_organisation_path
      expect(response.body).not_to include('Plain normal ticket')
    end

    it 'shows the same plain ticket when the user sets importance to "all"' do
      user.preference_store.update('cockpit_importance' => 'all')

      get select_organisation_path
      expect(response.body).to include('Plain normal ticket')
    end
  end

  describe 'rows layouts (T6)' do
    let!(:rows_setup) do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(org_a)
        project = create(:project, organisation: org_a, name: 'Alpha Project')
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                             options: { 'allowed_values' => [
                                               { 'value' => 'open', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] }
                                             ] })
        t = create(:ticket, project: project, organisation: org_a, title: 'Rows ticket',
                            custom_attributes: { 'status' => 'open', 'due_date' => 2.days.ago.to_date.iso8601 })
        create(:ticket_assignment, ticket: t, user: user)
        create(:notification, recipient: user, organisation: org_a, project: project, channel: 'in_app',
                              state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                              dedupe_fingerprint: 'fp-rows', notifiable: t)
        create(:personal_task, user: user, organisation: org_a, title: 'Rows todo')
      end
    end

    before do
      ActsAsTenant.current_tenant = nil
      sign_in user
    end

    def set_prefs(prefs)
      user.preference_store.update(prefs)
    end

    it 'renders the compact rows layout (200, no NoTenantSet)' do
      set_prefs('cockpit_layout' => 'rows_compact')
      get select_organisation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(org_a.name)
    end

    # The cockpit shows unread like the sidebar does: the red count pill of
    # Neo::UnreadMarkerComponent, not a dot of its own (29.09.2026).
    it 'marks unread notifications in the compact rows with the shared count marker' do
      set_prefs('cockpit_layout' => 'rows_compact')
      get select_organisation_path

      marker = Nokogiri::HTML(response.body).at_css('[data-unread-marker="count"]')
      expect(marker&.text).to eq('1')
      expect(marker['aria-label']).to eq(I18n.t('views.organisations.select.cockpit.unread_count', count: 1))
    end

    # A9: the detailed rows render the ticket deep-link (ticket.project must be eager-loaded) and a
    # notification row — all WITHOUT a tenant. A lazy association load would raise NoTenantSet (500).
    it 'renders the detailed rows layout with real cross-org data without NoTenantSet' do
      set_prefs('cockpit_layout' => 'rows_detailed', 'cockpit_importance' => 'all')
      get select_organisation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Rows ticket') # ticket row + eager project deep-link
      expect(response.body).to include('data-unread-marker="dot"') # unread notification dot rendered
    end

    it 'replaces the org tiles in rows mode (tiles section hidden, B2)' do
      set_prefs('cockpit_layout' => 'rows_compact')
      get select_organisation_path

      expect(response.body).not_to include(I18n.t('views.organisations.select.your_organisations'))
    end

    it 'keeps the org tiles in the stacked layout' do
      set_prefs('cockpit_layout' => 'stacked')
      get select_organisation_path

      expect(response.body).to include(I18n.t('views.organisations.select.your_organisations'))
    end

    it 'hides the action area when show_actions is off' do
      set_prefs('cockpit_layout' => 'rows_compact', 'cockpit_show_actions' => false)
      get select_organisation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-unread-marker') # no notification chip/dot without actions
    end

    it 'hides the personal to-dos when show_todos is off' do
      set_prefs('cockpit_layout' => 'rows_compact', 'cockpit_show_todos' => false)
      get select_organisation_path

      expect(response.body).not_to include('Rows todo')
    end

    it 'shows the personal to-dos when show_todos is on' do
      set_prefs('cockpit_layout' => 'rows_compact', 'cockpit_show_todos' => true)
      get select_organisation_path

      expect(response.body).to include('Rows todo')
    end
  end
end
