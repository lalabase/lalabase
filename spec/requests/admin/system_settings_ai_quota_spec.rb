# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent: the system-wide default budget + grace buffer, editable in the
# admin system settings (per-org overrides live on the org detail page).
RSpec.describe 'Admin::SystemSettings AI quota', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  it 'renders the AI quota section with the current defaults' do
    log_in_admin
    get admin_system_settings_path
    expect(response.body).to include(I18n.t('admin.system_settings.index.ai_quota_section'))
  end

  it 'updates the system-wide default budget and buffer' do
    log_in_admin
    patch admin_update_ai_quota_path,
          params: { ai_quota_monthly_credits: 333, ai_quota_grace_buffer_credits: 111 }

    expect(SystemSetting.ai_quota_monthly_credits).to eq(333)
    expect(SystemSetting.ai_quota_grace_buffer_credits).to eq(111)
    expect(response).to redirect_to(admin_system_settings_path)
  end

  it 'clamps a negative default to 0' do
    log_in_admin
    patch admin_update_ai_quota_path, params: { ai_quota_monthly_credits: -5 }
    expect(SystemSetting.ai_quota_monthly_credits).to eq(0)
  end

  # Review 2026-07-13 (codex): raising the system-wide default un-gates every org on
  # the default, so it must kick a backlog catch-up instead of waiting a whole month.
  it 'kicks a monthly catch-up when the default limit is raised' do
    SystemSetting.set_ai_quota_monthly_credits(100)
    SystemSetting.set_ai_quota_grace_buffer_credits(100)
    log_in_admin
    expect(AiQuotaMonthlyResumeJob).to receive(:perform_later)
    patch admin_update_ai_quota_path, params: { ai_quota_monthly_credits: 500, ai_quota_grace_buffer_credits: 100 }
  end

  it 'does NOT kick a catch-up when the default limit is lowered' do
    SystemSetting.set_ai_quota_monthly_credits(500)
    SystemSetting.set_ai_quota_grace_buffer_credits(100)
    log_in_admin
    expect(AiQuotaMonthlyResumeJob).not_to receive(:perform_later)
    patch admin_update_ai_quota_path, params: { ai_quota_monthly_credits: 100, ai_quota_grace_buffer_credits: 100 }
  end

  it 'requires a logged-in operator' do
    patch admin_update_ai_quota_path, params: { ai_quota_monthly_credits: 999 }
    expect(response).to redirect_to(admin_log_in_path)
  end
end
