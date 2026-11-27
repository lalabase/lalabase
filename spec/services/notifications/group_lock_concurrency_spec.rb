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

  def current_lock_timeout
    ActiveRecord::Base.connection.select_value("SELECT current_setting('lock_timeout')")
  end

  # Holds run :a after its first call of find_or_create_group has returned, until `release`
  # is fed. Every other caller passes; run :b leaves the lock_timeout of its connection
  # before and after its first call in `seen`.
  def hold_first_write_of_a(ready, release, seen = {})
    calls = Hash.new(0)
    mutex = Mutex.new
    allow_any_instance_of(described_class).to receive(:find_or_create_group).and_wrap_original do |original, *args|
      run = Thread.current[:group_lock_run]
      first = mutex.synchronize { (calls[run] += 1) == 1 }
      seen[:lock_timeout_before] = current_lock_timeout if run == :b && first
      answer = original.call(*args)
      seen[:lock_timeout_after] = current_lock_timeout if run == :b && first
      if run == :a && first
        ready << true
        release.pop
      end
      answer
    end
  end

  # The wait event of the first other backend of this database seen waiting for a lock, or
  # nil when none waits before the deadline.
  def lock_wait_of_other_backends(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      event = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT wait_event FROM pg_stat_activity
        WHERE wait_event_type = 'Lock' AND datname = current_database() AND pid <> pg_backend_pid()
        LIMIT 1
      SQL
      return event if event
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  # Ends the statement of every other backend of this database that waits for a lock. Called
  # in ensure, so a wait that never ends (a broken limit) fails its example instead of hanging
  # the file and every truncate after it. A no-op when nothing waits.
  def cancel_lock_waits
    ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT pg_cancel_backend(pid) FROM pg_stat_activity
      WHERE wait_event_type = 'Lock' AND datname = current_database() AND pid <> pg_backend_pid()
    SQL
  end

  def builder_params(activity, reader, ticket)
    { organisation: organisation, recipient: reader, actor: actor, notifiable: ticket,
      event_type: comment_event_type, channel: :in_app, priority: :normal, state: :queued, score: 50,
      payload: { activity_id: activity.id, action: 'post_added', post_ids: [activity.secondary_id.to_s] } }
  end

  # The builder called inside a transaction of its own connection, the way a caller other than
  # the fanout would. `before` runs first in that transaction. Answers the thread; its value is
  # what the call raised (nil when it returned), lock_timeout before and after the call inside
  # the transaction, and the connection's own lock_timeout before the transaction and after its
  # commit (a pooled connection that kept the wait's limit would carry it to every later job).
  def builder_in_thread(activity, reader, ticket, before: nil)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) do
          session_before = current_lock_timeout
          result = Notification.transaction do
            before&.call
            before_call = current_lock_timeout
            raised = begin
              described_class.new(activity, reader).find_or_create_group(builder_params(activity, reader, ticket))
              nil
            rescue Notifications::LockFailedError => e
              e.message
            end
            { raised: raised, before: before_call, after: current_lock_timeout }
          end
          result.merge(session_before: session_before, session_after: current_lock_timeout)
        end
      end
    end
  end

  # Run :a writes for its first recipient and is held; run :b starts and is watched until it
  # waits for a lock or the deadline passes; then :a is let go. Answers what :b waited on.
  def race(first_event, second_event, seen = {})
    ready = Queue.new
    release = Queue.new
    hold_first_write_of_a(ready, release, seen)
    first = run_in_thread(first_event, :a)
    Timeout.timeout(10) { ready.pop }
    second = run_in_thread(second_event, :b)
    waited = lock_wait_of_other_backends
    release << true
    [first, second].each { |thread| raise 'a run did not end' unless thread.join(20) }
    [first, second].each(&:value)
    waited
  ensure
    cancel_lock_waits
    release&.push(true)
    [first, second].compact.each { |thread| thread.join(5) || thread.kill }
  end

  # retry! clears error_message as it plans the next try, so the examples read the error a
  # run books (OutboxEvent#mark_failed), per event.
  def record_failures
    booked = Hash.new { |hash, key| hash[key] = [] }
    allow_any_instance_of(OutboxEvent).to receive(:mark_failed).and_wrap_original do |original, message|
      booked[original.receiver.id] << message
      original.call(message)
    end
    booked
  end

  def comment_event_type
    Notifications::Constants.derive_event_type('ticket.post_added', 'post_added')
  end

  # A committed unread row of the group, one that may take the next comment: in the inbox,
  # normal priority, inside the window (the factory dates a row an hour back), with the post
  # ids of an earlier comment.
  def unread_row(reader, ticket, group_key, post, at:)
    create(:notification, recipient: reader, organisation: organisation, notifiable: ticket, project: project,
                          actor: actor, group_key: group_key, group_count: 1, event_type: comment_event_type,
                          channel: 'in_app', state: 'queued', priority: 'normal', score: 50,
                          payload: { 'action' => 'post_added', 'actor_ids' => [actor.id], 'post_ids' => [post.id.to_s] },
                          created_at: at, updated_at: at, first_event_at: at, last_event_at: at, happened_at: at)
  end

  def processed_without_retry(*events)
    events.each do |event|
      expect(event.reload).to have_attributes(retry_count: 0, error_message: nil)
      expect(event.processed_at).to be_present
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

  describe 'two runs of one group at once' do
    let(:now) { Time.current }

    def events_of_one_group(ticket, readers)
      first_event = comment_event(ticket, at: now)
      second_event = comment_event(ticket, at: now)
      group_key = described_class.new(first_event.activity, readers.first).build
      expect(described_class.new(second_event.activity, readers.first).build).to eq(group_key)
      [first_event, second_event, group_key]
    end

    # The second run waits for the group lock while the first holds it, so the row lock of
    # the first never stands between them, and neither run fails.
    it 'lets the second wait for the first, then fold into the row each recipient already has' do
      ticket, readers = ticket_with_readers(2)
      first_event, second_event, group_key = events_of_one_group(ticket, readers)
      earlier_post = create(:post, ticket: ticket, user: actor, organisation: organisation)
      readers.each { |reader| unread_row(reader, ticket, group_key, earlier_post, at: now) }
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to match_array(readers.map { |reader| [reader.id, 1] })

      seen = {}
      waited = race(first_event, second_event, seen)

      expect(waited).to eq('advisory')
      processed_without_retry(first_event, second_event)
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to match_array(readers.map { |reader| [reader.id, 3] })
      expect(seen[:lock_timeout_before]).to be_present
      expect(seen[:lock_timeout_after]).to eq(seen[:lock_timeout_before])
    end

    # The second run sees what the first committed, so one group stays one row.
    it 'lets the second wait for the first, then fold into the rows the first wrote' do
      ticket, readers = ticket_with_readers(2)
      first_event, second_event, = events_of_one_group(ticket, readers)
      expect(inbox_rows(ticket)).not_to exist

      waited = race(first_event, second_event)

      expect(waited).to eq('advisory')
      processed_without_retry(first_event, second_event)
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to match_array(readers.map { |reader| [reader.id, 2] })
    end
  end

  # A statement that fails in the database aborts the transaction. The lock must end with it,
  # or it would stay with the pooled connection and shut out every other run of the group.
  describe 'a statement that fails inside the lock' do
    after { ActiveRecord::Base.connection.execute('SELECT pg_advisory_unlock_all()') }

    it 'leaves no advisory lock behind, and the run books the error of that statement' do
      ticket, = ticket_with_readers(1)
      event = comment_event(ticket, at: Time.current)
      booked = record_failures
      held = []
      allow_any_instance_of(described_class).to receive(:create_new_group).and_wrap_original do |_original, *|
        held << advisory_locks_of_this_backend
        ActiveRecord::Base.connection.execute('SELECT 1/0')
      end
      expect(advisory_locks_of_this_backend).to eq(0)

      OutboxEvent.find(event.id).process!

      expect(held.size).to eq(1)
      expect(held.first).to be_positive
      expect(advisory_locks_of_this_backend).to eq(0)
      expect(event.reload).to have_attributes(processed_at: nil, retry_count: 1)
      expect(booked[event.id]).to contain_exactly(a_string_matching(/division by zero/))
    end
  end

  # A holder that does not let go. The second run waits GROUP_LOCK_WAIT, gives up, keeps
  # nothing and is planned again, as a run that fails for any other reason.
  describe 'a run that does not get the lock in time' do
    it 'fails, writes nothing and is planned again, and the holder goes through' do
      stub_const("#{described_class}::GROUP_LOCK_WAIT", 0.2.seconds)
      now = Time.current
      ticket, readers = ticket_with_readers(2)
      first_event = comment_event(ticket, at: now)
      second_event = comment_event(ticket, at: now)
      group_key = described_class.new(first_event.activity, readers.first).build
      booked = record_failures

      ready = Queue.new
      release = Queue.new
      hold_first_write_of_a(ready, release)
      first = run_in_thread(first_event, :a)
      Timeout.timeout(10) { ready.pop }
      second = run_in_thread(second_event, :b)
      raise 'the second run did not end' unless second.join(10)

      second.value
      expect(first).to be_alive
      expect(second_event.reload).to have_attributes(processed_at: nil, retry_count: 1)
      expect(second_event.available_at).to be > Time.current
      expect(booked[second_event.id]).to contain_exactly("Could not acquire lock for group key: #{group_key}")

      release << true
      raise 'the first run did not end' unless first.join(20)

      first.value
      processed_without_retry(first_event)
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to match_array(readers.map { |reader| [reader.id, 1] })
      expect(inbox_rows(ticket).map { |row| row.payload['activity_id'] }.uniq).to eq([first_event.activity_id])
    ensure
      cancel_lock_waits
      release << true if release
      [first, second].compact.each { |thread| thread.join(5) || thread.kill }
    end

    # A lock timeout aborts the transaction it happens in. The wait has a savepoint of its
    # own, so after LockFailedError the caller's transaction still runs statements: the
    # rest of the run, or a caller that rescues the error.
    it 'leaves the transaction of its caller usable after the wait runs out' do
      stub_const("#{described_class}::GROUP_LOCK_WAIT", 0.2.seconds)
      ticket, readers = ticket_with_readers(1)
      first_event = comment_event(ticket, at: Time.current)
      activity = comment_event(ticket, at: first_event.activity.created_at).activity

      ready = Queue.new
      release = Queue.new
      hold_first_write_of_a(ready, release)
      first = run_in_thread(first_event, :a)
      Timeout.timeout(10) { ready.pop }

      caller = builder_in_thread(activity, readers.first, ticket)
      raise 'the waiting caller did not end' unless caller.join(10)

      result = caller.value
      expect(result[:raised]).to eq("Could not acquire lock for group key: #{described_class.new(activity, readers.first).build}")
      expect(result[:before]).to be_present
      expect(result[:after]).to eq(result[:before])
      release << true
      raise 'the first run did not end' unless first.join(20)

      first.value
      processed_without_retry(first_event)
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to eq([[readers.first.id, 1]])
    ensure
      cancel_lock_waits
      release << true if release
      [first, caller].compact.each { |thread| thread.join(5) || thread.kill }
    end
  end

  # The wait sets lock_timeout for itself only. A caller that holds a limit of its own gets that
  # limit back after a wait that succeeds, not the setting of the session.
  describe 'a wait that succeeds' do
    it 'puts back the lock_timeout its caller had set' do
      ticket, readers = ticket_with_readers(1)
      first_event = comment_event(ticket, at: Time.current)
      activity = comment_event(ticket, at: first_event.activity.created_at).activity

      ready = Queue.new
      release = Queue.new
      hold_first_write_of_a(ready, release)
      first = run_in_thread(first_event, :a)
      Timeout.timeout(10) { ready.pop }

      own_limit = -> { ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1234ms'") }
      caller = builder_in_thread(activity, readers.first, ticket, before: own_limit)
      waited = lock_wait_of_other_backends
      release << true
      raise 'the waiting caller did not end' unless caller.join(20) && first.join(20)

      result = caller.value
      first.value
      expect(waited).to eq('advisory')
      expect(result.slice(:raised, :before, :after)).to eq(raised: nil, before: '1234ms', after: '1234ms')
      expect(result[:session_before]).to be_present
      expect(result[:session_after]).to eq(result[:session_before])
      expect(inbox_rows(ticket).pluck(:recipient_id, :group_count)).to eq([[readers.first.id, 2]])
    ensure
      cancel_lock_waits
      release << true if release
      [first, caller].compact.each { |thread| thread.join(5) || thread.kill }
    end
  end
end
