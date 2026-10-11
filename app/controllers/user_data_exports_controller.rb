# frozen_string_literal: true

# Self-service GDPR data export (Art. 15/20) — root-level like
# AccountDeletionsController: a data-subject right, available to EVERY
# authenticated user, never gated by an org role (plan: Berechtigungen/D2).
#
# Security posture:
# - create requires password re-auth: an export is the jackpot for a hijacked
#   session, a live session alone must not be enough
# - the singular resource is bound to current_user — there is no id param, so
#   cross-user access is impossible by construction
# - download redirects to a short-lived signed blob URL, the mail only ever
#   links to this page
class UserDataExportsController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  # GET /user_data_export
  def show
    authorize UserDataExport
    @export = current_export
  end

  # POST /user_data_export
  def create
    authorize UserDataExport

    unless current_user.valid_password?(params[:current_password].to_s)
      UserActivity.track_failure!(current_user, UserActivity::ACTIONS[:data_export_requested],
                                  'wrong_password', request: request)
      redirect_to user_data_export_path, alert: t('controllers.user_data_exports.create.wrong_password')
      return
    end

    export = current_user.user_data_exports.new

    if export.save
      UserDataExportJob.perform_later(export)
      UserActivity.track!(current_user, UserActivity::ACTIONS[:data_export_requested], request: request)
      redirect_to user_data_export_path, notice: t('controllers.user_data_exports.create.requested')
    else
      redirect_to user_data_export_path, alert: export.errors.full_messages.to_sentence
    end
  rescue ActiveRecord::RecordNotUnique
    # Double-submit race: both requests pass the model validation, the partial
    # unique index (one active export per user) is the arbiter — D5.
    redirect_to user_data_export_path, alert: t('controllers.user_data_exports.create.already_running')
  end

  # GET /user_data_export/download
  def download
    export = current_export
    authorize(export || UserDataExport)

    if export&.downloadable?
      UserActivity.track!(current_user, UserActivity::ACTIONS[:data_export_downloaded], request: request)
      redirect_to rails_blob_url(export.archive, disposition: 'attachment')
    elsif export&.expired?
      redirect_to user_data_export_path, alert: t('controllers.user_data_exports.download.expired')
    else
      redirect_to user_data_export_path, alert: t('controllers.user_data_exports.download.not_ready')
    end
  end

  private

  def current_export
    current_user.user_data_exports.order(created_at: :desc).first
  end
end
