# frozen_string_literal: true

class Admin::SystemSettingsController < Admin::ApplicationController
  def index
    load_settings
    @legal_identity = LegalIdentity.load
  end

  # Operator identity (LegalIdentity): the operator name and the external legal pages the
  # core links on login, invitation, AI opt-in and data export. Blank fields are saved too,
  # that is how a link is removed. An invalid URL saves nothing and shows the page again
  # with the error, so the other three values are not half-updated.
  def update_legal_identity
    @legal_identity = LegalIdentity.new(params.fetch(:legal_identity, {}).permit(*LegalIdentity::ATTRIBUTES))

    if @legal_identity.save
      flash[:notice] = t('flash.admin.system_settings.legal_identity_updated')
      redirect_to admin_system_settings_path
    else
      load_settings
      render :index, status: :unprocessable_content
    end
  end

  # KI-Kontingent (S3): the SYSTEM-WIDE default budget + grace buffer (credits).
  # Per-org overrides are edited on the admin organisation page.
  def update_ai_quota
    old_limit = SystemSetting.ai_quota_monthly_credits + SystemSetting.ai_quota_grace_buffer_credits
    monthly = params[:ai_quota_monthly_credits]
    buffer = params[:ai_quota_grace_buffer_credits]
    SystemSetting.set_ai_quota_monthly_credits(monthly) if monthly.present?
    SystemSetting.set_ai_quota_grace_buffer_credits(buffer) if buffer.present?
    # Raising the system-wide default un-gates every org that runs on the default —
    # re-drive their paused embeddings now instead of waiting for the monthly reset.
    # The job is quota-aware and only touches orgs that actually have a backlog.
    new_limit = SystemSetting.ai_quota_monthly_credits + SystemSetting.ai_quota_grace_buffer_credits
    AiQuotaMonthlyResumeJob.perform_later if new_limit > old_limit
    flash[:notice] = t('flash.admin.system_settings.ai_quota_updated')
    redirect_to admin_system_settings_path
  end

  def update_registration
    SystemSetting.set(:allow_registration, params[:allow_registration] == 'true')

    SystemSetting.set(:registration_disabled_message, params[:registration_disabled_message]) if params[:registration_disabled_message].present?

    respond_to do |format|
      format.turbo_stream do
        @registration_allowed = SystemSetting.allow_registration?
        @registration_message = SystemSetting.registration_disabled_message

        render turbo_stream: [
          turbo_stream.replace('registration-settings',
                               partial: 'admin/system_settings/registration_settings',
                               locals: {
                                 registration_allowed: @registration_allowed,
                                 registration_message: @registration_message
                               }),
          turbo_stream.prepend('flash',
                               partial: 'layouts/flash',
                               locals: { flash: { notice: t('flash.admin.system_settings.registration_updated') } })
        ]
      end

      format.html do
        flash[:notice] = t('flash.admin.system_settings.registration_updated')
        redirect_to admin_system_settings_path
      end
    end
  end

  def update_deletion_settings
    if params[:grace_period_days].present?
      days = params[:grace_period_days].to_i
      SystemSetting.set_account_deletion_grace_period_days(days)
    end

    respond_to do |format|
      format.turbo_stream do
        @grace_period_days = SystemSetting.account_deletion_grace_period_days

        render turbo_stream: [
          turbo_stream.replace('deletion-settings',
                               partial: 'admin/system_settings/deletion_settings',
                               locals: { grace_period_days: @grace_period_days }),
          turbo_stream.prepend('flash',
                               partial: 'layouts/flash',
                               locals: { flash: { notice: t('flash.admin.system_settings.deletion_updated') } })
        ]
      end

      format.html do
        flash[:notice] = t('flash.admin.system_settings.deletion_updated')
        redirect_to admin_system_settings_path
      end
    end
  end

  private

  def load_settings
    @registration_allowed = SystemSetting.allow_registration?
    @registration_message = SystemSetting.registration_disabled_message
    @grace_period_days = SystemSetting.account_deletion_grace_period_days
    @ai_quota_monthly_credits = SystemSetting.ai_quota_monthly_credits
    @ai_quota_grace_buffer_credits = SystemSetting.ai_quota_grace_buffer_credits
  end
end
