# frozen_string_literal: true

class CancelAccountDeletionsController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session
  before_action :ensure_deletion_scheduled

  # GET /cancel_account_deletion
  def show
    @days_remaining = current_user.days_until_deletion
    @scheduled_date = current_user.scheduled_deletion_at
  end

  # POST /cancel_account_deletion
  def create
    if current_user.cancel_scheduled_deletion!(reason: params[:reason])
      # Track the cancellation in UserActivity if available
      current_user.track_deletion_canceled(reason: params[:reason]) if current_user.respond_to?(:track_deletion_canceled)

      flash[:notice] = t('flash.cancel_account_deletions.canceled')
      redirect_to root_path
    else
      flash[:alert] = t('flash.cancel_account_deletions.cancel_error')
      redirect_to cancel_account_deletion_path
    end
  end

  private

  def ensure_deletion_scheduled
    return if current_user.deletion_scheduled?

    flash[:alert] = t('flash.cancel_account_deletions.no_deletion_scheduled')
    redirect_to root_path
  end
end
