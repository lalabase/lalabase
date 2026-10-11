# frozen_string_literal: true

require 'rails_helper'

# HTTP contract of the self-service export (doc/user_data_export_plan.md §8):
# password re-auth gates create, the throttle answers with a friendly message,
# the double-submit race resolves via the DB index, downloads redirect to a
# signed blob URL for the OWNER only (the singular resource carries no id, so
# cross-user access is impossible by construction), and every request/download
# leaves a security audit event.
RSpec.describe 'UserDataExports', type: :request do
  let(:password) { 'password123' }
  let(:user) { create(:user, password: password) }

  before { ActiveJob::Base.queue_adapter = :test }

  describe 'GET /user_data_export' do
    it 'redirects to login when signed out' do
      get user_data_export_path
      expect(response).to redirect_to(new_user_session_path)
    end

    context 'signed in' do
      before { sign_in user }

      it 'renders the request form without any export' do
        get user_data_export_path

        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('user_data_export.request_button'))
      end

      # One example per state (a loop inside ONE example trips Prosopite:
      # repeated identical queries across iterations read as N+1). Each state
      # asserts its VISIBLE contract: the status title, plus whether the
      # request form and the download button may appear — status 200 alone
      # would never break when the view shows the wrong state.
      it 'renders the pending state without a new-request form' do
        create(:user_data_export, user: user)

        get user_data_export_path

        expect(response.body).to include(I18n.t('user_data_export.status.pending.title'))
        expect(response.body).not_to include(I18n.t('user_data_export.request_button'))
      end

      it 'renders the processing state without a new-request form' do
        create(:user_data_export, :processing, user: user)

        get user_data_export_path

        expect(response.body).to include(I18n.t('user_data_export.status.processing.title'))
        expect(response.body).not_to include(I18n.t('user_data_export.request_button'))
      end

      it 'renders the completed state with the download button' do
        create(:user_data_export, :completed, user: user)

        get user_data_export_path

        expect(response.body).to include(I18n.t('user_data_export.status.completed.title'))
        expect(response.body).to include(I18n.t('user_data_export.download_button'))
      end

      it 'renders the expired state with a new-request form, without download' do
        create(:user_data_export, :expired, user: user)

        get user_data_export_path

        expect(response.body).to include(I18n.t('user_data_export.status.expired.title'))
        expect(response.body).to include(I18n.t('user_data_export.request_button'))
        expect(response.body).not_to include(I18n.t('user_data_export.download_button'))
      end

      it 'renders the failed state with a new-request form' do
        create(:user_data_export, :failed, user: user)

        get user_data_export_path

        expect(response.body).to include(I18n.t('user_data_export.status.failed.title'))
        expect(response.body).to include(I18n.t('user_data_export.request_button'))
      end
    end
  end

  describe 'POST /user_data_export' do
    it 'redirects to login when signed out' do
      expect do
        post user_data_export_path, params: { current_password: password }
      end.not_to change(UserDataExport, :count)
      expect(response).to redirect_to(new_user_session_path)
    end

    context 'signed in' do
      before { sign_in user }

      it 'rejects a missing password and records a failed audit event' do
        expect do
          post user_data_export_path, params: { current_password: '' }
        end.not_to change(UserDataExport, :count)

        expect(flash[:alert]).to eq(I18n.t('controllers.user_data_exports.create.wrong_password'))
        expect(UserActivity.where(action: 'data_export_requested', status: 'failed').count).to eq(1)
      end

      it 'rejects a wrong password' do
        expect do
          post user_data_export_path, params: { current_password: 'falsch' }
        end.not_to change(UserDataExport, :count)
      end

      it 'creates the export, enqueues the job and records the audit event' do
        expect do
          post user_data_export_path, params: { current_password: password }
        end.to change(UserDataExport, :count).by(1)
           .and have_enqueued_job(UserDataExportJob)

        expect(flash[:notice]).to eq(I18n.t('controllers.user_data_exports.create.requested'))
        expect(UserActivity.where(action: 'data_export_requested', status: 'success').count).to eq(1)
      end

      it 'answers the 24h throttle with the model message' do
        create(:user_data_export, :completed, user: user, created_at: 1.hour.ago)

        expect do
          post user_data_export_path, params: { current_password: password }
        end.not_to change(UserDataExport, :count)

        expect(flash[:alert]).to include(I18n.t('activerecord.errors.models.user_data_export.too_frequent'))
      end

      it 'resolves the double-submit race via the DB index (D5)' do
        allow_any_instance_of(UserDataExport).to receive(:save)
          .and_raise(ActiveRecord::RecordNotUnique, 'duplicate key')

        post user_data_export_path, params: { current_password: password }

        expect(response).to redirect_to(user_data_export_path)
        expect(flash[:alert]).to eq(I18n.t('controllers.user_data_exports.create.already_running'))
      end
    end
  end

  describe 'GET /user_data_export/download' do
    it 'redirects to login when signed out' do
      get download_user_data_export_path
      expect(response).to redirect_to(new_user_session_path)
    end

    context 'signed in' do
      before { sign_in user }

      it 'redirects the owner to a signed blob URL and records the audit event' do
        create(:user_data_export, :completed, user: user)

        get download_user_data_export_path

        expect(response).to have_http_status(:redirect)
        expect(response.location).to include('/rails/active_storage/blobs')
        expect(UserActivity.where(action: 'data_export_downloaded').count).to eq(1)
      end

      it 'only ever serves the CURRENT user\'s export (no id parameter exists)' do
        other = create(:user)
        create(:user_data_export, :completed, user: other)

        get download_user_data_export_path

        expect(response).to redirect_to(user_data_export_path)
        expect(flash[:alert]).to eq(I18n.t('controllers.user_data_exports.download.not_ready'))
      end

      it 'refuses an expired export' do
        create(:user_data_export, :expired, user: user)

        get download_user_data_export_path

        expect(response).to redirect_to(user_data_export_path)
        expect(flash[:alert]).to eq(I18n.t('controllers.user_data_exports.download.expired'))
        expect(UserActivity.where(action: 'data_export_downloaded').count).to eq(0)
      end

      it 'refuses while the export is still processing' do
        create(:user_data_export, :processing, user: user)

        get download_user_data_export_path

        expect(flash[:alert]).to eq(I18n.t('controllers.user_data_exports.download.not_ready'))
      end
    end
  end
end
