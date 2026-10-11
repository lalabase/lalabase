# frozen_string_literal: true

class AccountDeletionsController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  # GET /account_deletion/new
  # Shows confirmation form for account deletion
  def new
    @user = current_user
  end

  # POST /account_deletion
  # Performs self-service account deletion. Asks for the current password, like
  # the data export: a hijacked session must not be able to delete the account.
  def create
    unless current_user.valid_password?(params[:current_password].to_s)
      redirect_to new_account_deletion_path, alert: t('flash.account_deletions.wrong_password')
      return
    end

    service = DeleteAccountService.new(
      target_user: current_user,
      requester: current_user,
      source: 'selfservice',
      reason: params[:reason]
    )

    if service.call
      grace_period_days = SystemSetting.account_deletion_grace_period_days

      if grace_period_days == 0
        # Immediate deletion
        sign_out current_user
        redirect_to root_path, notice: t('flash.account_deletions.deleted_immediately')
      else
        # Scheduled deletion — scheduled_deletion_at is guaranteed set by the service
        flash[:notice] = t('flash.account_deletions.scheduled',
                           date: l(current_user.scheduled_deletion_at, format: :long),
                           days: grace_period_days)
        redirect_to root_path
      end
    else
      redirect_to new_account_deletion_path,
                  alert: t('flash.account_deletions.error', error: service.errors.join(', '))
    end
  end
end
