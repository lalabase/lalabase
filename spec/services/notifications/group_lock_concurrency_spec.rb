# frozen_string_literal: true

require 'rails_helper'

# The lock of a notification group (Notifications::GroupKeyBuilder#find_or_create_group),
# against real connections and committed data. A group is one record, one kind of action and
# one five-minute bucket; every recipient of one event writes into the same group.
#
# A run is held right after its first call of find_or_create_group has returned, inside the
# transaction of OutboxEvent#process!, until the example releases it. Holding it inside the
# call would measure a lock that is given back at the end of the call as if it were held. A
# second run is then watched in pg_stat_activity, never timed with a sleep.
RSpec.describe Notifications::GroupKeyBuilder, 'group lock', :ci_guard do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  let(:organisation) { create(:organisation, name: 'Nord GmbH') }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:actor) { account_admin }

  def account_admin
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  # A ticket and the readers who follow it: the recipients of every comment on it.
  def ticket_with_readers(count)
    ticket = create(:ticket, project: project, creator: actor)
    readers = Array.new(count) { account_admin }
    readers.each { |reader| NotificationSubscription.create!(user: reader, subscribable: ticket, mode: 'follow') }
    [ticket, readers]
  end

  # A comment on the ticket, in the inbox only (skip_email), its activity at `at`. Two comments
  # on one ticket at one time belong to one group.
  def comment_event(ticket, at:)
    post = create(:post, ticket: ticket, user: actor, organisation: organisation)
    activity = create(:activity, organisation: organisation, trackable: ticket, actor: actor, action: 'post_added',
                                 key: 'ticket.post_added', secondary: post, parameters: { 'skip_email' => true },
                                 created_at: at)
    OutboxEvent.find_by!(activity: activity)
  end

  def run_in_thread(event, name)
    Thread.new do
      Thread.current[:group_lock_run] = name
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) { OutboxEvent.find(event.id).process! }
      end
    end
  end

  def advisory_locks_of_this_backend
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
    ).to_i
  end

  # Holds run :a after its first call of find_or_create_group has returned, until `release`
  # is fed. Every other caller passes.
  def hold_first_write_of_a(ready, release)
    calls = Hash.new(0)
    mutex = Mutex.new
    allow_any_instance_of(described_class).to receive(:find_or_create_group).and_wrap_original do |original, *args|
      run = Thread.current[:group_lock_run]
      first = mutex.synchronize { (calls[run] += 1) == 1 }
      answer = original.call(*args)
      if run == :a && first
        ready << true
        release.pop
      end
      answer
    end
  end

  def inbox_rows(ticket)
    Notification.where(notifiable: ticket, channel: 'in_app')
  end

  describe 'pins of what the lock leans on' do
    # A transaction lock taken outside a transaction ends with its statement. Standing alone,
    # the builder therefore opens a transaction of its own, so its lock covers the write.
    it 'holds an advisory lock while it writes and none after it returns, when no transaction is open' do
      ticket, readers = ticket_with_readers(1)
      reader = readers.first
      activity = comment_event(ticket, at: Time.current).activity
      params = { organisation: organisation, recipient: reader, actor: actor, notifiable: ticket,
                 event_type: 'ticket_commented', channel: :in_app, priority: :normal, state: :queued, score: 50,
                 payload: { activity_id: activity.id, action: 'post_added', post_ids: [activity.secondary_id.to_s] } }
      held = []
      allow(Notification).to receive(:create!).and_wrap_original do |original, *args, **options|
        held << advisory_locks_of_this_backend
        original.call(*args, **options)
      end
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      expect(advisory_locks_of_this_backend).to eq(0)

      row = described_class.new(activity, reader).find_or_create_group(params)

      expect(row).to be_persisted
      expect(held.size).to eq(1)
      expect(held.first).to be_positive
      expect(advisory_locks_of_this_backend).to eq(0)
    end

    # One run has one group key. A run of another group does not wait for it.
    it 'does not hold up a run of another group while a run waits at the barrier' do
      now = Time.current
      first_ticket, first_readers = ticket_with_readers(2)
      second_ticket, second_readers = ticket_with_readers(2)
      first_event = comment_event(first_ticket, at: now)
      second_event = comment_event(second_ticket, at: now)
      expect(described_class.new(first_event.activity, first_readers.first).build)
        .not_to eq(described_class.new(second_event.activity, second_readers.first).build)

      ready = Queue.new
      release = Queue.new
      hold_first_write_of_a(ready, release)
      first = run_in_thread(first_event, :a)
      Timeout.timeout(10) { ready.pop }

      OutboxEvent.find(second_event.id).process!

      expect(second_event.reload).to have_attributes(retry_count: 0, error_message: nil)
      expect(second_event.processed_at).to be_present
      expect(inbox_rows(second_ticket).pluck(:recipient_id)).to match_array(second_readers.map(&:id))
      expect(first_event.reload.processed_at).to be_nil

      release << true
      expect(first.join(20)).to be_present
      expect(first_event.reload).to have_attributes(retry_count: 0, error_message: nil)
      expect(first_event.processed_at).to be_present
    ensure
      release << true if release
      first&.join(2)
      first&.kill if first&.alive?
    end
  end
end
