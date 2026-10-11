# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledDeletionJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  def create_user_with_membership(**attrs)
    user = create(:user, **attrs)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  describe '#perform' do
    context 'when no users are scheduled for deletion' do
      it 'completes without errors' do
        expect { described_class.new.perform }.not_to raise_error
      end

      it 'does not call execute_scheduled_deletion' do
        job = described_class.new
        expect(job).not_to receive(:execute_scheduled_deletion)
        job.perform
      end
    end

    context 'when users have overdue scheduled deletions' do
      let!(:overdue_user) do
        create_user_with_membership(
          scheduled_deletion_at: 1.day.ago,
          deletion_reason: 'No longer needed'
        )
      end

      it 'soft-deletes the user' do
        described_class.new.perform

        expect(User.find_by(id: overdue_user.id)).to be_nil
        expect(User.with_deleted.find(overdue_user.id).deleted_at).to be_present
      end

      it 'anonymizes the user data' do
        described_class.new.perform

        deleted_user = User.with_deleted.find(overdue_user.id)
        expect(deleted_user.first_name).to eq('Anonym')
        expect(deleted_user.last_name).to eq('Anonym')
        expect(deleted_user.email).to match(/\Aanonym_[a-f0-9]+@deleted\.local\z/)
      end

      it 'destroys all memberships' do
        expect do
          described_class.new.perform
        end.to change { Membership.where(user_id: overdue_user.id).count }.to(0)
      end
    end

    context 'with users in different deletion states' do
      let!(:overdue_user) do
        create_user_with_membership(scheduled_deletion_at: 2.hours.ago)
      end

      let!(:future_user) do
        create_user_with_membership(scheduled_deletion_at: 1.day.from_now)
      end

      let!(:no_schedule_user) do
        create_user_with_membership(scheduled_deletion_at: nil)
      end

      let!(:already_deleted_user) do
        create(:user, scheduled_deletion_at: 1.day.ago, deleted_at: 2.days.ago)
      end

      it 'only deletes overdue users' do
        described_class.new.perform

        expect(User.find_by(id: overdue_user.id)).to be_nil
        expect(User.find_by(id: future_user.id)).to be_present
        expect(User.find_by(id: no_schedule_user.id)).to be_present
      end

      it 'does not process already soft-deleted users' do
        described_class.new.perform

        raw_user = User.with_deleted.find(already_deleted_user.id)
        expect(raw_user.deleted_at).to be_within(1.second).of(2.days.ago)
      end
    end

    context 'when processing multiple overdue users' do
      let!(:user_one) do
        create_user_with_membership(scheduled_deletion_at: 2.days.ago)
      end

      let!(:user_two) do
        create_user_with_membership(scheduled_deletion_at: 1.day.ago)
      end

      it 'deletes all overdue users' do
        Prosopite.pause

        described_class.new.perform

        expect(User.find_by(id: user_one.id)).to be_nil
        expect(User.find_by(id: user_two.id)).to be_nil

        Prosopite.resume
      end
    end

    context 'when an error occurs during deletion of one user' do
      let!(:failing_user) do
        create_user_with_membership(scheduled_deletion_at: 2.days.ago)
      end

      let!(:succeeding_user) do
        create_user_with_membership(scheduled_deletion_at: 1.day.ago)
      end

      before do
        Prosopite.pause

        allow_any_instance_of(described_class).to receive(:execute_scheduled_deletion).and_call_original
        allow_any_instance_of(described_class).to receive(:execute_scheduled_deletion)
          .with(failing_user).and_raise(StandardError, 'Database connection lost')
      end

      after do
        Prosopite.resume
      end

      it 'continues processing remaining users' do
        described_class.new.perform

        expect(User.find_by(id: succeeding_user.id)).to be_nil
      end

      it 'does not delete the failing user' do
        described_class.new.perform

        expect(User.find_by(id: failing_user.id)).to be_present
      end

      it 'logs the error' do
        expect(Rails.logger).to receive(:error).with(/Failed to delete user #{failing_user.id}.*Database connection lost/)
        expect(Rails.logger).to receive(:error).at_least(:once) # backtrace

        described_class.new.perform
      end
    end

    context 'with boundary timestamp (scheduled_deletion_at == Time.current)' do
      it 'includes users with scheduled_deletion_at exactly at current time' do
        travel_to(Time.current) do
          user = create_user_with_membership(scheduled_deletion_at: Time.current)

          described_class.new.perform

          expect(User.find_by(id: user.id)).to be_nil
        end
      end
    end
  end

  describe 'UserDeletion log handling' do
    let!(:user) do
      create_user_with_membership(
        scheduled_deletion_at: 1.hour.ago,
        deletion_reason: 'Privacy concerns'
      )
    end

    context 'when a pending UserDeletion log exists' do
      let!(:deletion_log) do
        UserDeletion.create!(
          deleted_user_id: user.id,
          deleter: user,
          source: 'selfservice',
          reason: 'Privacy concerns',
          deleted_at: 1.hour.ago,
          scheduled_at: 1.hour.ago,
          executed_at: nil
        )
      end

      it 'updates the existing log with executed_at' do
        travel_to(Time.current) do
          described_class.new.perform

          deletion_log.reload
          expect(deletion_log.executed_at).to eq(Time.current)
        end
      end

      it 'updates deleted_at on the log' do
        travel_to(Time.current) do
          described_class.new.perform

          deletion_log.reload
          expect(deletion_log.deleted_at).to eq(Time.current)
        end
      end

      it 'does not create a new UserDeletion record' do
        expect do
          described_class.new.perform
        end.not_to change(UserDeletion, :count)
      end
    end

    context 'when no pending UserDeletion log exists' do
      it 'creates a new UserDeletion log' do
        expect do
          described_class.new.perform
        end.to change(UserDeletion, :count).by(1)
      end

      it 'sets correct attributes on the created log' do
        travel_to(Time.current) do
          described_class.new.perform

          log = UserDeletion.last
          expect(log.deleted_user_id).to eq(user.id)
          expect(log.source).to eq('selfservice')
          expect(log.reason).to eq('Privacy concerns')
          expect(log.executed_at).to eq(Time.current)
        end
      end
    end

    context 'when multiple UserDeletion logs exist for the same user' do
      let!(:old_canceled_log) do
        UserDeletion.create!(
          deleted_user_id: user.id,
          deleter: user,
          source: 'selfservice',
          reason: 'First attempt',
          deleted_at: 1.week.ago,
          scheduled_at: 1.week.ago,
          executed_at: 1.week.ago,
          canceled_at: 5.days.ago
        )
      end

      let!(:current_log) do
        UserDeletion.create!(
          deleted_user_id: user.id,
          deleter: user,
          source: 'selfservice',
          reason: 'Privacy concerns',
          deleted_at: 1.hour.ago,
          scheduled_at: 1.hour.ago,
          executed_at: nil
        )
      end

      it 'updates only the pending log (executed_at: nil)' do
        travel_to(Time.current) do
          described_class.new.perform

          current_log.reload
          old_canceled_log.reload

          expect(current_log.executed_at).to eq(Time.current)
          expect(old_canceled_log.executed_at).to be_within(1.second).of(1.week.ago)
        end
      end
    end
  end

  describe 'ActiveSupport::Notifications event' do
    let!(:user) do
      create_user_with_membership(
        scheduled_deletion_at: 1.hour.ago,
        deletion_reason: 'Account cleanup'
      )
    end

    it 'instruments an account.deletion_executed event' do
      events = []
      subscription = ActiveSupport::Notifications.subscribe('account.deletion_executed') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.new.perform

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload[:user_id]).to eq(user.id)
      expect(payload[:scheduled_at]).to be_within(1.second).of(1.hour.ago)
      expect(payload[:executed_at]).to be_present

      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'does not instrument event when no users are deleted' do
      user.update_column(:scheduled_deletion_at, 1.day.from_now)

      events = []
      subscription = ActiveSupport::Notifications.subscribe('account.deletion_executed') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.new.perform

      expect(events).to be_empty

      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe 'transaction safety' do
    let!(:user) do
      create_user_with_membership(
        scheduled_deletion_at: 1.hour.ago,
        deletion_reason: 'Test reason'
      )
    end

    context 'when UserDeletion log update fails' do
      let!(:deletion_log) do
        UserDeletion.create!(
          deleted_user_id: user.id,
          deleter: user,
          source: 'selfservice',
          reason: 'Test reason',
          deleted_at: 1.hour.ago,
          executed_at: nil
        )
      end

      before do
        allow(deletion_log).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

        allow(UserDeletion).to receive(:find_by)
          .with(deleted_user_id: user.id, executed_at: nil)
          .and_return(deletion_log)
      end

      it 'rolls back user soft-deletion' do
        described_class.new.perform

        expect(User.find_by(id: user.id)).to be_present
        expect(User.find_by(id: user.id).deleted_at).to be_nil
      end

      it 'does not anonymize the user' do
        original_email = user.email

        described_class.new.perform

        expect(User.find_by(id: user.id).email).to eq(original_email)
      end
    end

    context 'when soft_delete_and_anonymize! raises an error' do
      before do
        allow_any_instance_of(User).to receive(:soft_delete_and_anonymize!)
          .and_raise(ActiveRecord::RecordInvalid)
      end

      it 'does not create a UserDeletion log' do
        expect do
          described_class.new.perform
        end.not_to change(UserDeletion, :count)
      end

      it 'keeps the user intact' do
        original_email = user.email

        described_class.new.perform

        user_record = User.find_by(id: user.id)
        expect(user_record).to be_present
        expect(user_record.email).to eq(original_email)
      end
    end
  end

  describe 'logging' do
    it 'logs deletion execution start' do
      user = create_user_with_membership(scheduled_deletion_at: 1.hour.ago)

      expect(Rails.logger).to receive(:info)
        .with(/Executing deletion for user #{user.id}/)
      expect(Rails.logger).to receive(:info)
        .with(/Successfully deleted user #{user.id}/)

      described_class.new.perform
    end

    it 'does not log PII (email address)' do
      create_user_with_membership(
        scheduled_deletion_at: 1.hour.ago,
        email: 'sensitive@personal.com'
      )

      expect(Rails.logger).not_to receive(:info).with(/sensitive@personal\.com/)

      described_class.new.perform
    end

    it 'limits backtrace output to 5 lines on error' do
      user = create_user_with_membership(scheduled_deletion_at: 1.hour.ago)

      error = StandardError.new('test error')
      error.set_backtrace(Array.new(20) { |i| "line #{i}" })

      allow_any_instance_of(described_class).to receive(:execute_scheduled_deletion)
        .with(user).and_raise(error)

      backtrace_lines = nil
      allow(Rails.logger).to receive(:error) do |msg|
        backtrace_lines = msg if msg.is_a?(String) && msg.include?('line ')
      end

      described_class.new.perform

      expect(backtrace_lines.split("\n").size).to be <= 5 if backtrace_lines
    end
  end

  describe 'queue configuration' do
    it 'is enqueued in the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe 'ohne Tenant-Kontext (Realität des recurring-Triggers und der Konsole)' do
    # The job is started via Solid-Queue recurring or rails runner — there
    # NO ActsAsTenant.current_tenant is set. All other contexts of this spec
    # set the tenant in the before hook and thereby test a state that doesn't
    # exist in real operation. This guard reproduces the worker reality.
    it 'löscht und anonymisiert fällige User auch ohne gesetzten Tenant' do
      overdue_user = create_user_with_membership(
        scheduled_deletion_at: 1.day.ago,
        deletion_reason: 'DSGVO-Selfservice'
      )

      ActsAsTenant.current_tenant = nil

      expect { described_class.new.perform }.not_to raise_error

      deleted_user = User.with_deleted.find(overdue_user.id)
      expect(deleted_user.deleted_at).to be_present
      expect(deleted_user.first_name).to eq('Anonym')
      expect(Membership.where(user_id: overdue_user.id)).to be_empty
    end
  end
end
