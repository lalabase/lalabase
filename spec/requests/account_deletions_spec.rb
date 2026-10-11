# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AccountDeletions', type: :request do
  let(:user) { create(:user) }

  describe 'GET /account_deletion/new' do
    context 'when not authenticated' do
      it 'redirects to login' do
        get new_account_deletion_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'when authenticated' do
      before { sign_in user }

      it 'returns success' do
        get new_account_deletion_path
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /account_deletion' do
    context 'when not authenticated' do
      it 'redirects to login' do
        post account_deletion_path, params: { current_password: user.password, reason: 'Test' }
        expect(response).to redirect_to(new_user_session_path)
      end

      it 'does not delete any user' do
        expect do
          post account_deletion_path, params: { current_password: user.password, reason: 'Test' }
        end.not_to(change { User.where.not(deleted_at: nil).count })
      end
    end

    context 'when authenticated' do
      before { sign_in user }

      context 'with immediate deletion (grace_period = 0)' do
        before do
          allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(0)
        end

        it 'soft-deletes and anonymizes the user' do
          post account_deletion_path, params: { current_password: user.password, reason: 'No longer needed' }

          user.reload
          expect(user.deleted_at).to be_present
          expect(user.email).to match(/anonym_\w+@deleted\.local/)
        end

        it 'signs the user out' do
          post account_deletion_path, params: { current_password: user.password, reason: 'No longer needed' }

          get new_account_deletion_path
          expect(response).to redirect_to(new_user_session_path)
        end

        it 'redirects to root with immediate deletion flash' do
          post account_deletion_path, params: { current_password: user.password, reason: 'No longer needed' }

          expect(response).to redirect_to(root_path)
          expect(flash[:notice]).to eq(I18n.t('flash.account_deletions.deleted_immediately'))
        end

        it 'creates an audit trail record' do
          expect do
            post account_deletion_path, params: { current_password: user.password, reason: 'No longer needed' }
          end.to change(UserDeletion, :count).by(1)

          deletion = UserDeletion.last
          expect(deletion.deleted_user_id).to eq(user.id)
          expect(deletion.deleter_id).to eq(user.id)
          expect(deletion.deleter_type).to eq('User')
          expect(deletion.source).to eq('selfservice')
          expect(deletion.reason).to eq('No longer needed')
          expect(deletion.executed_at).to be_present
        end

        it 'works without a reason' do
          post account_deletion_path, params: { current_password: user.password }

          user.reload
          expect(user.deleted_at).to be_present
          expect(response).to redirect_to(root_path)

          deletion = UserDeletion.last
          expect(deletion.reason).to be_nil
        end
      end

      context 'with grace period (grace_period > 0)' do
        before do
          allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(14)
        end

        it 'schedules the user for deletion instead of deleting immediately' do
          post account_deletion_path, params: { current_password: user.password, reason: 'Taking a break' }

          user.reload
          expect(user.deleted_at).to be_nil
          expect(user.scheduled_deletion_at).to be_within(5.seconds).of(14.days.from_now)
        end

        it 'does NOT sign the user out' do
          post account_deletion_path, params: { current_password: user.password, reason: 'Taking a break' }

          get new_account_deletion_path
          expect(response).to have_http_status(:success)
        end

        it 'redirects to root with scheduled deletion flash' do
          post account_deletion_path, params: { current_password: user.password, reason: 'Taking a break' }

          expect(response).to redirect_to(root_path)
          scheduled_date = user.reload.scheduled_deletion_at
          expected_date = I18n.l(scheduled_date, format: :long)
          expect(flash[:notice]).to eq(
            I18n.t('flash.account_deletions.scheduled', date: expected_date, days: 14)
          )
        end

        it 'creates an audit trail record with scheduled_at' do
          expect do
            post account_deletion_path, params: { current_password: user.password, reason: 'Taking a break' }
          end.to change(UserDeletion, :count).by(1)

          deletion = UserDeletion.last
          expect(deletion.scheduled_at).to be_present
          expect(deletion.executed_at).to be_nil
        end
      end

      context 'when the service fails' do
        it 'redirects back with error message' do
          service = instance_double(DeleteAccountService, call: false, errors: ['Permission denied'])
          allow(DeleteAccountService).to receive(:new).and_return(service)

          post account_deletion_path, params: { current_password: user.password, reason: 'Test' }

          expect(response).to redirect_to(new_account_deletion_path)
          expect(flash[:alert]).to include('Permission denied')
        end

        it 'does not delete the user' do
          service = instance_double(DeleteAccountService, call: false, errors: ['Error'])
          allow(DeleteAccountService).to receive(:new).and_return(service)

          post account_deletion_path, params: { current_password: user.password, reason: 'Test' }

          expect(user.reload.deleted_at).to be_nil
        end

        it 'does not sign out the user' do
          service = instance_double(DeleteAccountService, call: false, errors: ['Error'])
          allow(DeleteAccountService).to receive(:new).and_return(service)

          post account_deletion_path, params: { current_password: user.password, reason: 'Test' }

          get new_account_deletion_path
          expect(response).to have_http_status(:success)
        end

        it 'does not create an audit trail record' do
          service = instance_double(DeleteAccountService, call: false, errors: ['Error'])
          allow(DeleteAccountService).to receive(:new).and_return(service)

          expect do
            post account_deletion_path, params: { current_password: user.password, reason: 'Test' }
          end.not_to change(UserDeletion, :count)
        end

        it 'joins multiple errors with comma' do
          service = instance_double(DeleteAccountService, call: false, errors: ['Error 1', 'Error 2'])
          allow(DeleteAccountService).to receive(:new).and_return(service)

          post account_deletion_path, params: { current_password: user.password, reason: 'Test' }

          expect(flash[:alert]).to include('Error 1, Error 2')
        end
      end

      context 'when the user is already soft-deleted' do
        before do
          user.update_columns(deleted_at: 1.hour.ago)
        end

        it 'fails with already deleted error' do
          post account_deletion_path, params: { current_password: user.password }

          expect(response).to redirect_to(new_account_deletion_path)
          expect(flash[:alert]).to be_present
        end
      end

      context 'with a long reason (> 500 chars)' do
        it 'fails with validation error' do
          post account_deletion_path, params: { current_password: user.password, reason: 'a' * 501 }

          expect(response).to redirect_to(new_account_deletion_path)
          expect(flash[:alert]).to include('500')
        end
      end

      describe 'service initialization' do
        it 'passes correct parameters to DeleteAccountService' do
          expect(DeleteAccountService).to receive(:new).with(
            target_user: user,
            requester: user,
            source: 'selfservice',
            reason: 'My reason'
          ).and_call_original

          post account_deletion_path, params: { current_password: user.password, reason: 'My reason' }
        end

        it 'passes nil reason when no reason given' do
          expect(DeleteAccountService).to receive(:new).with(
            target_user: user,
            requester: user,
            source: 'selfservice',
            reason: nil
          ).and_call_original

          post account_deletion_path, params: { current_password: user.password }
        end
      end
    end
  end

  # A hijacked session must not be able to delete the account: the form asks
  # for the password, like the data export. The examples above are the control.
  describe 'POST /account_deletion without the current password' do
    before do
      sign_in user
      allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(0)
    end

    it 'deletes nothing and sends the user back to the form' do
      post account_deletion_path, params: { current_password: 'wrong-password', reason: 'x' }

      expect(user.reload.deleted_at).to be_nil
      expect(response).to redirect_to(new_account_deletion_path)
      expect(flash[:alert]).to eq(I18n.t('flash.account_deletions.wrong_password'))
    end
  end

  # Devise's own registrations#destroy deleted the row at once: no password,
  # no grace period, no deletion log. It now leads to the deletion form.
  describe 'DELETE /users' do
    before { sign_in user }

    it 'deletes nothing and leads to the deletion form' do
      expect { delete user_registration_path }.not_to change(User, :count)

      expect(user.reload.deleted_at).to be_nil
      expect(response).to redirect_to(new_account_deletion_path)
    end
  end
end
