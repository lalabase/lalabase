# frozen_string_literal: true

require 'rails_helper'

# What: Organisations::OverviewWidgetsController#show — single-widget Turbo refresh for the
#       interactive period switch on the personal week widgets.
# Type: Request spec (full stack: auth, whitelist, permission gate, preference persistence).
# Why:  This endpoint renders a widget out of band, so it must enforce the SAME gate as the
#       dashboard (time access), reject unknown widgets, harden the period against junk input,
#       and persist the choice so a reload keeps it.
RSpec.describe 'Organisations::OverviewWidgets', type: :request do
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

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'GET #show' do
    it 'renders the requested widget frame for a valid key + period and persists the choice' do
      sign_in admin
      get organisation_overview_widget_path(organisation, 'my_week_stats', period: 'this_month')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="overview_widget_my_week_stats"')
      expect(response.body).to include(I18n.t('dashboard.briefing.period.title.this_month'))
      expect(admin.reload.overview_widget_period('my_week_stats')).to eq('this_month')
    end

    it 'works for the chart widget too' do
      sign_in admin
      get organisation_overview_widget_path(organisation, 'my_week_chart', period: 'this_quarter')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="overview_widget_my_week_chart"')
    end

    it 'normalises an unknown period to the default and persists that' do
      sign_in admin
      get organisation_overview_widget_path(organisation, 'my_week_stats', period: 'bogus')

      expect(response).to have_http_status(:ok)
      expect(admin.reload.overview_widget_period('my_week_stats')).to eq('this_week')
    end

    it 'returns 404 for an unknown widget key' do
      sign_in admin
      get organisation_overview_widget_path(organisation, 'org_activity_feed', period: 'this_week')

      expect(response).to have_http_status(:not_found)
    end

    it 'forbids a viewer without time access and does not persist anything' do
      sign_in member
      get organisation_overview_widget_path(organisation, 'my_week_stats', period: 'this_month')

      expect(response).to have_http_status(:forbidden)
      expect(member.reload.preferences['overview_widget_periods']).to be_blank
    end
  end
end
