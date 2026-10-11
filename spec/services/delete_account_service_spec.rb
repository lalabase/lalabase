# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeleteAccountService, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:admin_user) { create(:user) }
  let(:beuser) { create(:beuser) }

  describe '#call' do
    context 'self-service deletion' do
      subject(:service) do
        described_class.new(
          target_user: user,
          requester: user,
          source: 'selfservice',
          reason: 'No longer needed'
        )
      end

      it 'successfully deletes user account' do
        result = service.call
        puts "Service errors: #{service.errors}" unless result
        expect(result).to be true
      end

      it 'soft deletes and anonymizes the user' do
        original_email = user.email
        service.call
        user.reload

        expect(user.deleted_at).to be_present
        expect(user.email).not_to eq(original_email)
        expect(user.email).to match(/anonym_\w+@deleted\.local/)
        expect(user.first_name).to eq('Anonym')
        expect(user.last_name).to eq('Anonym')
      end

      it 'creates audit trail record' do
        expect { service.call }.to change(UserDeletion, :count).by(1)

        deletion_record = UserDeletion.last
        expect(deletion_record.deleted_user_id).to eq(user.id)
        expect(deletion_record.deleter_id).to eq(user.id)
        expect(deletion_record.deleter_type).to eq('User')
        expect(deletion_record.source).to eq('selfservice')
        expect(deletion_record.reason).to eq('No longer needed')
      end

      it 'broadcasts deletion event' do
        # Allow other notifications to pass through
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

        expect(ActiveSupport::Notifications).to receive(:instrument)
          .with('account.deleted', hash_including(
                                     user_id: user.id,
                                     deleter_id: user.id,
                                     deleter_type: 'User',
                                     source: 'selfservice'
                                   ))
          .and_call_original

        service.call
      end
    end

    context 'backend deletion by beuser' do
      subject(:service) do
        described_class.new(
          target_user: user,
          requester: beuser,
          source: 'backend',
          reason: 'Policy violation'
        )
      end

      it 'successfully deletes user account' do
        expect(service.call).to be true
      end

      it 'creates audit trail with beuser as deleter' do
        service.call

        deletion_record = UserDeletion.last
        expect(deletion_record.deleted_user_id).to eq(user.id)
        expect(deletion_record.deleter_id).to eq(beuser.id)
        expect(deletion_record.deleter_type).to eq('Beuser')
        expect(deletion_record.source).to eq('backend')
        expect(deletion_record.reason).to eq('Policy violation')
      end
    end

    # The whole grace-period BRANCH below was previously never exercised: the
    # test suite forces grace = 0 (spec/support/system_settings_test_defaults),
    # so every other example takes the immediate branch. These stub a positive
    # grace period to cover the scheduling half of `call` and the
    # `|| source == 'backend'` clause.
    context 'scheduled deletion (self-service with grace period > 0)' do
      before { allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(14) }

      subject(:service) do
        described_class.new(
          target_user: user,
          requester: user,
          source: 'selfservice',
          reason: 'Cooling-off please'
        )
      end

      it 'schedules instead of deleting (no soft-delete or anonymisation yet)' do
        # Mutant kill: a `call` that always took the immediate branch would
        # soft-delete the user here, reddening the deleted_at / email assertions.
        travel_to(Time.utc(2030, 1, 1, 12, 0, 0)) do
          original_email = user.email

          expect(service.call).to be true
          user.reload

          expect(user.deleted_at).to be_nil
          expect(user.email).to eq(original_email)
          expect(user.scheduled_deletion_at).to eq(14.days.from_now)
          expect(user.deletion_reason).to eq('Cooling-off please')
        end
      end

      it 'logs the scheduled deletion with scheduled_at set and executed_at nil' do
        expect { service.call }.to change(UserDeletion, :count).by(1)

        record = UserDeletion.last
        expect(record.scheduled_at).to be_present
        expect(record.executed_at).to be_nil
        expect(record.source).to eq('selfservice')
      end

      it 'broadcasts account.deletion_scheduled (not account.deleted)' do
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

        expect(ActiveSupport::Notifications).to receive(:instrument)
          .with('account.deletion_scheduled', hash_including(user_id: user.id, source: 'selfservice'))
          .and_call_original

        service.call
      end

      it 'forwards to track_deletion_scheduled when the hook exists (respond_to? guard)' do
        # Same defensive pattern as track_deletion_canceled: the hook is not
        # defined on User, so the guard prevents a NoMethodError on the normal
        # scheduled path (implicitly covered by the examples above). Here we pin
        # the positive side — when present it receives the schedule details.
        received = nil
        user.define_singleton_method(:track_deletion_scheduled) { |**kwargs| received = kwargs }

        service.call

        expect(received[:reason]).to eq('Cooling-off please')
        expect(received[:scheduled_for]).to be_present
      end
    end

    context 'backend deletion ignores the configured grace period' do
      before { allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(30) }

      subject(:service) do
        described_class.new(
          target_user: user,
          requester: beuser,
          source: 'backend',
          reason: 'Policy violation'
        )
      end

      it 'deletes immediately even though a grace period is configured' do
        # Pins the `|| source == 'backend'` clause: backend deletions bypass the
        # cooling-off window. Mutant kill: dropping that clause would SCHEDULE the
        # backend deletion, so deleted_at would be nil and scheduled_deletion_at
        # would be set here.
        expect(service.call).to be true
        user.reload

        expect(user.deleted_at).to be_present
        expect(user.first_name).to eq('Anonym')
        expect(user.scheduled_deletion_at).to be_nil
      end
    end

    context 'permission validation' do
      context 'when regular user tries to delete another user' do
        let(:other_user) { create(:user) }

        subject(:service) do
          described_class.new(
            target_user: user,
            requester: other_user,
            source: 'selfservice'
          )
        end

        it 'fails with permission error' do
          expect(service.call).to be false
          expect(service.errors).to include('You do not have permission to delete this account')
        end

        it 'does not delete the user' do
          service.call
          expect(user.reload.deleted_at).to be_nil
        end

        it 'does not create audit trail' do
          expect { service.call }.not_to change(UserDeletion, :count)
        end
      end

      context 'when admin user tries to delete another user' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            admin_role = organisation.find_or_create_account_admin_role
            create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
            create(:membership, user: user, organisation: organisation, active: true)
          end
        end

        subject(:service) do
          described_class.new(
            target_user: user,
            requester: admin_user,
            source: 'selfservice'
          )
        end

        it 'fails with permission error' do
          expect(service.call).to be false
          expect(service.errors).to include('You do not have permission to delete this account')
        end
      end
    end

    context 'when user is already deleted' do
      before { user.soft_delete_and_anonymize! }

      subject(:service) do
        described_class.new(
          target_user: user,
          requester: user,
          source: 'selfservice'
        )
      end

      it 'fails with appropriate error' do
        expect(service.call).to be false
        expect(service.errors).to include('User is already deleted')
      end

      it 'does not create additional audit trail' do
        expect { service.call }.not_to change(UserDeletion, :count)
      end
    end

    context 'invalid source parameter' do
      subject(:service) do
        described_class.new(
          target_user: user,
          requester: user,
          source: 'invalid'
        )
      end

      it 'fails with validation error' do
        expect(service.call).to be false
        expect(service.errors).to include('Invalid source: must be selfservice or backend')
      end
    end

    context 'database transaction rollback' do
      subject(:service) do
        described_class.new(
          target_user: user,
          requester: user,
          source: 'selfservice'
        )
      end

      before do
        # Mock UserDeletion.log_deletion to raise an error
        allow(UserDeletion).to receive(:log_deletion).and_raise(ActiveRecord::RecordInvalid.new(UserDeletion.new))
      end

      it 'rolls back user deletion when audit creation fails' do
        service.call

        # User should not be deleted if audit creation failed
        expect(user.reload.deleted_at).to be_nil
        expect(user.reload.email).not_to match(/anonym_\w+@deleted\.local/)
      end

      it 'returns false and includes error' do
        expect(service.call).to be false
        expect(service.errors).not_to be_empty
      end
    end
  end

  describe 'input validation' do
    it 'requires target_user' do
      service = described_class.new(
        target_user: nil,
        requester: user,
        source: 'selfservice'
      )

      expect(service.call).to be false
      expect(service.errors).to include('Target user is required')
    end

    it 'requires requester' do
      service = described_class.new(
        target_user: user,
        requester: nil,
        source: 'selfservice'
      )

      expect(service.call).to be false
      expect(service.errors).to include('Requester is required')
    end

    it 'requires source' do
      service = described_class.new(
        target_user: user,
        requester: user,
        source: nil
      )

      expect(service.call).to be false
      expect(service.errors).to include('Source is required')
    end
  end

  describe 'reason length validation' do
    it 'accepts reasons up to 500 characters' do
      service = described_class.new(
        target_user: user,
        requester: user,
        source: 'selfservice',
        reason: 'a' * 500
      )

      expect(service.call).to be true
    end

    it 'rejects reasons over 500 characters' do
      service = described_class.new(
        target_user: user,
        requester: user,
        source: 'selfservice',
        reason: 'a' * 501
      )

      expect(service.call).to be false
      expect(service.errors).to include('Reason is too long (maximum 500 characters)')
    end
  end

  describe 'error handling' do
    subject(:service) do
      described_class.new(
        target_user: user,
        requester: user,
        source: 'selfservice'
      )
    end

    it 'logs errors when deletion fails' do
      allow(user).to receive(:soft_delete_and_anonymize!).and_raise(StandardError.new('Database error'))

      expect(Rails.logger).to receive(:error).with(/Failed to process account deletion/)

      service.call
    end

    it 'includes generic error message for unexpected failures' do
      allow(user).to receive(:soft_delete_and_anonymize!).and_raise(StandardError.new('Database error'))

      service.call

      expect(service.errors).to include('Database error')
    end
  end
end
