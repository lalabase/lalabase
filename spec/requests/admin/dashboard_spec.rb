# frozen_string_literal: true

require 'rails_helper'

# Request spec for the admin dashboard landing page. Its job is purely
# navigational now: three grouped blocks of fully clickable tiles
# (Verwaltung / Monitoring / Einstellungen) instead of the old
# stats-plus-quick-actions layout. These tests pin that restructure so a
# regression (dropped tile, missing group, resurrected quick-action footer)
# fails loudly.
RSpec.describe 'Admin::Dashboard', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  describe 'GET /admin/dashboard' do
    it 'requires a logged-in operator' do
      get admin_dashboard_path

      expect(response).to redirect_to(admin_log_in_path)
    end

    it 'renders the three group headings as section headers' do
      log_in_admin

      get admin_dashboard_path

      expect(response).to have_http_status(:ok)
      # Match the section <h2> specifically -- the same words also appear as nav
      # dropdown labels, so a bare include() would pass even without the sections.
      %w[group_management group_monitoring group_settings].each do |group|
        label = Regexp.escape(I18n.t("admin.dashboard.#{group}"))
        expect(response.body).to match(%r{<h2[^>]*>\s*#{label}\s*</h2>}m)
      end
    end

    # The instance admin's own tiles. The operator console adds a fourth,
    # Abrechnungskonten, through the slot :dashboard_management_tiles; that tile,
    # its count and the four-column grid are pinned in the engine's
    # spec/requests/admin/operator_extensions_spec.rb, the three-column grid
    # without it in without_operator_extensions_spec.rb.
    it 'links every Verwaltung tile' do
      log_in_admin

      get admin_dashboard_path

      expect(response.body).to include(admin_organisations_path)
      expect(response.body).to include(admin_users_path)
      expect(response.body).to include(admin_beusers_path)
    end

    it 'links every Monitoring tile' do
      log_in_admin

      get admin_dashboard_path

      expect(response.body).to include('/admin/jobs')
      expect(response.body).to include(admin_email_logs_path)
      expect(response.body).to include(admin_monitoring_path)
    end

    it 'links every Einstellungen tile' do
      log_in_admin

      get admin_dashboard_path

      expect(response.body).to include(admin_system_settings_path)
      expect(response.body).to include(admin_ai_credentials_path)
      expect(response.body).to include(admin_prompt_personas_path)
    end

    # The cleanup removed the "Schnellaktionen" panel and the per-tile
    # "Alle anzeigen" footer links -- tiles are clickable as a whole now.
    it 'no longer renders the quick-actions panel or view-all footer links' do
      log_in_admin

      get admin_dashboard_path

      expect(response.body).not_to include('Schnellaktionen')
      expect(response.body).not_to include('Alle anzeigen')
    end
  end
end
