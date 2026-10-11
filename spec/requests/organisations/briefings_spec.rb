# frozen_string_literal: true

require 'rails_helper'

# What: Organisation overview (briefings#show) — the configurable-widget render path.
# Type: Request spec (full stack: auth, layout cascade, widget render).
# Why:  Pins the two things the B3 wiring must get right end-to-end: (1) the org root renders the
#       configurable overview (default layout = converted widgets) instead of the old hardcoded view;
#       (2) D1 — the "no time access -> redirect to inbox" guard is GONE, so a member without time
#       access still gets the overview (200) and the widgets self-gate (activity/projects show,
#       the time-tracking week widgets are hidden).
RSpec.describe 'Organisations::Briefings', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'GET #show (organisation overview)' do
    it 'renders the configurable overview with the default widgets for an admin' do
      sign_in admin
      get organisation_root_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('dashboard.briefing.sections.activity.title'))
      expect(response.body).to include(I18n.t('dashboard.briefing.sections.projects.title'))
      expect(response.body).to include(I18n.t('dashboard.briefing.week.title'))
    end

    it 'no longer redirects a member without time access to the inbox (D1) and self-gates the widgets' do
      sign_in member
      get organisation_root_path(organisation)

      expect(response).to have_http_status(:ok)
      # Activity + projects widgets carry no permission -> visible even without time access.
      expect(response.body).to include(I18n.t('dashboard.briefing.sections.activity.title'))
      # The week widgets ARE permission-gated (time_sessions:read in any project) -> hidden here.
      expect(response.body).not_to include(I18n.t('dashboard.briefing.week.title'))
    end

    # The portfolio widgets (Lane C) render in the default layout. This pins the route-bearing list
    # renders end-to-end (the my_open_tickets ticket path + the my_mentions target path), which the
    # component specs deliberately skip (render_inline has no working routes).
    it 'renders the portfolio widgets incl. the route-bearing ticket + mention lists for an admin' do
      ActsAsTenant.with_tenant(organisation) do
        ticket = create(:ticket, project: project, title: 'Mein offenes Ticket')
        ticket.assignees << admin
        # Priority/status come from the per-project custom attributes; set raw values (no definition
        # needed for display) via update_columns to bypass attribute validation in this render test.
        ticket.update_columns(custom_attributes: ticket.custom_attributes.merge('status' => 'In Arbeit', 'priority' => 'Hoch'))
        create(:notification, recipient: admin, actor: member, organisation: organisation,
                              notifiable: ticket, channel: 'in_app', event_type: 'mention')
      end

      sign_in admin
      get organisation_root_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('overview.cards.active_projects'))        # org_stats_cards
      expect(response.body).to include(I18n.t('overview.widgets.billing_overview'))     # billing_overview
      expect(response.body).to include(I18n.t('overview.widgets.recent_notifications')) # recent_notifications (route-bearing list)
      expect(response.body).to include('Mein offenes Ticket')                           # my_open_tickets row (ticket route resolves)
      expect(response.body).to include('In Arbeit')                                     # my_open_tickets sub-line: status value
      expect(response.body).to include('Hoch')                                          # my_open_tickets sub-line: priority value
      expect(response.body).to include(member.display_name)                             # my_mentions row (target path resolves)
    end

    it 'gates the time-tracking billing widget for a member without time access, but keeps org_stats_cards' do
      sign_in member
      get organisation_root_path(organisation)

      expect(response.body).to include(I18n.t('overview.cards.active_projects')) # always renders (self-scoped to zero)
      expect(response.body).not_to include(I18n.t('overview.widgets.billing_overview')) # time-gated -> hidden
    end

    # Regression: the per-project portfolio table sums billing hours over ALL time (no occurred_on
    # filter — see DailyBriefing#projects_overview). The drill-down links into "Zeiten" must
    # therefore carry date_range=all, otherwise the controller defaults to 'this_month' and the
    # drilled-down total no longer matches the figure the widget showed.
    it 'drills the billing-hours columns down to ALL times so the destination matches the widget figure' do
      ActsAsTenant.with_tenant(organisation) do
        group = create(:time_session_group, organisation: organisation, creator: admin)
        # in_billing: billed=false, group set; occurred two months ago -> outside the old 'this_month' default.
        create(:time_session, project: project, organisation: organisation, creator: admin,
                              time_session_group: group, billed: false, duration: 120, occurred_on: 2.months.ago)
        # without_billing: billed=false, no group.
        create(:time_session, project: project, organisation: organisation, creator: admin,
                              billed: false, duration: 90, occurred_on: 2.months.ago)
      end

      sign_in admin
      get organisation_root_path(organisation)

      expect(response).to have_http_status(:ok)
      # Both per-project drill-down links and the now-clickable footer totals must scope to all time.
      expect(response.body).to include('date_range=all')
      expect(response.body).to include('status_filters%5B%5D=in_billing')
      expect(response.body).to include('status_filters%5B%5D=without_billing')
      expect(response.body).to include("project_id_filter=#{project.id}")
    end
  end
end
