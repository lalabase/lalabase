# frozen_string_literal: true

require 'rails_helper'

# One run of an outbox event writes its notifications recipient by recipient. A run that
# fails leaves none of them behind, so the retry starts from nothing.
#
# Until 2026-10-31 the rows stayed. The retry stopped at the first recipient it had already
# served, whose dedupe_fingerprint was taken, and the people after that one got nothing, on
# every retry up to MAX_RETRY_COUNT. One lost advisory lock was enough, and several uploads
# at once were enough to lose one (GroupKeyBuilder shares the lock per project and action).
RSpec.describe OutboxEvent, '#process! after a failed run', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let!(:actor) { account_admin }

  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  def account_admin
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  def event_on(trackable, action:, key:, **attributes)
    activity = create(:activity, organisation: organisation, trackable: trackable, actor: actor, action: action,
                                 key: key, parameters: {}, **attributes)
    described_class.find_by!(activity: activity)
  end

  def fail_once_at_write(number)
    writes = 0
    allow_any_instance_of(Notifications::GroupKeyBuilder).to receive(:find_or_create_group).and_wrap_original do |original, *args|
      writes += 1
      raise 'one-off failure' if writes == number

      original.call(*args)
    end
  end

  def run(event)
    Prosopite.pause { event.reload.process! }
  end

  shared_examples 'a run that starts over' do
    it 'keeps nothing of the failed run and leaves the event to its retry' do
      fail_once_at_write(2)

      run(event)

      expect(Notification.where(notifiable: subject_of_event)).not_to exist
      expect(event.reload).to have_attributes(processed_at: nil, retry_count: 1)
      expect(event.available_at).to be > Time.current
    end

    it 'reaches everybody once on the retry' do
      fail_once_at_write(2)

      2.times { run(event) }

      expect(event.reload.processed_at).to be_present
      expect(Notification.where(notifiable: subject_of_event).pluck(:recipient_id, :channel))
        .to match_array(readers.flat_map { |reader| [[reader.id, 'in_app'], [reader.id, 'email']] })
    end

    # In a transaction of the caller an ActiveRecord::Rollback would otherwise be swallowed,
    # silently, and the half run would stay.
    it 'keeps nothing either when the caller holds a transaction' do
      event
      fail_once_at_write(2)

      ActiveRecord::Base.transaction { run(event) }

      expect(Notification.where(notifiable: subject_of_event)).not_to exist
      expect(event.reload).to have_attributes(processed_at: nil, retry_count: 1)
    end

    # The other half of the same promise: an untroubled run writes all of it in one go.
    it 'needs no retry when nothing fails' do
      run(event)

      expect(event.reload).to have_attributes(retry_count: 0, error_message: nil)
      expect(event.processed_at).to be_present
      expect(Notification.where(notifiable: subject_of_event).count).to eq(readers.size * 2)
    end
  end

  describe 'an event on a project' do
    let!(:readers) { Array.new(3) { account_admin } }
    let(:subject_of_event) { project }
    let(:event) { event_on(project, action: 'updated', key: 'project.updated') }

    it_behaves_like 'a run that starts over'
  end

  describe 'an event on a ticket' do
    let(:ticket) { create(:ticket, project: project, creator: actor) }
    let!(:readers) do
      Prosopite.pause do
        Array.new(3) { account_admin }.each do |reader|
          NotificationSubscription.create!(user: reader, subscribable: ticket, mode: 'follow')
        end
      end
    end
    let(:subject_of_event) { ticket }
    let(:event) { event_on(ticket, action: 'status_changed', key: 'ticket.status_changed') }

    it_behaves_like 'a run that starts over'
  end

  describe 'the last step of a run' do
    let!(:reader) { account_admin }
    let(:event) { event_on(project, action: 'updated', key: 'project.updated') }

    # Booked outside the transaction, the rows would stay behind a failure in between,
    # and the retry would stop at the dedupe fingerprint again.
    it 'belongs to the transaction: nothing stays when it fails' do
      event
      allow(event).to receive(:mark_processed!).and_raise('connection lost')

      expect { Prosopite.pause { event.process! } }.to raise_error('connection lost')

      expect(Notification.where(notifiable: project)).not_to exist
    end
  end

  # What a second worker holds: the event as it was before the first worker finished. The
  # row lock is what shows it the truth, the check above the lock cannot.
  describe 'a second worker with an old copy of the event' do
    let!(:reader) { account_admin }
    let(:event) { event_on(project, action: 'updated', key: 'project.updated') }

    it 'does not run the event again' do
      old_copy = described_class.find(event.id)
      run(event)
      expect(old_copy.processed_at).to be_nil

      expect(Notifications::FanoutService).not_to receive(:new)

      Prosopite.pause { old_copy.process! }
    end
  end

  # The failure is booked after the lock of the run is gone, so another worker can step in
  # between. Without a lock of its own the booking wrote the count of its old copy.
  describe 'booking a failure' do
    let!(:reader) { account_admin }
    let(:event) { event_on(project, action: 'updated', key: 'project.updated') }

    def between_the_locks(&other_worker)
      locks = 0
      allow(event).to receive(:with_lock).and_wrap_original do |original, *args, **options, &locked|
        locks += 1
        other_worker.call if locks == 2
        original.call(*args, **options, &locked)
      end
    end

    before do
      event
      allow(event).to receive(:process_event).and_return({ success: false, error: 'one-off failure' })
    end

    it 'counts on from the row, not from its own old copy' do
      between_the_locks { described_class.where(id: event.id).update_all(retry_count: 3) }

      run(event)

      expect(event.reload.retry_count).to eq(4)
    end

    it 'leaves an event alone that another worker has finished' do
      between_the_locks { described_class.where(id: event.id).update_all(processed_at: Time.current) }

      run(event)

      expect(event.reload).to have_attributes(retry_count: 0, error_message: nil)
    end
  end

  # A row of an earlier event that the failed run had already added to. Kept, it would be
  # added to again on the retry, and the inbox would count one comment twice.
  describe 'a group that a failed run had already added to' do
    let(:ticket) { create(:ticket, project: project, creator: actor) }
    let!(:reader) { account_admin }

    def comment_event
      post = create(:post, ticket: ticket, user: actor, organisation: organisation)
      event_on(ticket, action: 'post_added', key: 'ticket.post_added', secondary: post)
    end

    it 'counts the new event once' do
      NotificationSubscription.create!(user: reader, subscribable: ticket, mode: 'follow')
      run(comment_event)
      group = Notification.find_by!(recipient: reader, notifiable: ticket, channel: 'in_app')
      expect(group.group_count).to eq(1)

      fail_once_at_write(2)
      second = comment_event
      run(second)
      expect(group.reload.group_count).to eq(1)

      run(second)
      expect(group.reload.group_count).to eq(2)
    end
  end

  # A real error of the database leaves the transaction unusable, so the bookkeeping of
  # the failure cannot share it. Inside it, mark_failed raised and no retry was planned.
  describe 'a database error inside the run' do
    let(:event) { event_on(project, action: 'updated', key: 'project.updated') }

    before do
      allow(AccessCheck::ProjectAccessService).to receive(:users_with_access) do
        ActiveRecord::Base.connection.execute('SELECT 1/0')
      end
    end

    it 'still leaves the event to its retry' do
      expect { run(event) }.not_to raise_error

      expect(event.reload).to have_attributes(processed_at: nil, retry_count: 1)
      expect(event.available_at).to be > Time.current
    end
  end
end
