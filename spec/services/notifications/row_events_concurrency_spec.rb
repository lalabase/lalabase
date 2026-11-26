# frozen_string_literal: true

require 'rails_helper'

# The row lock of Notifications::RowEvents.fold!, against a second connection.
# A fold waits for a connection that holds the row and decides on what that
# connection committed, not on the object its caller loaded before. And while
# it asks the caller's rule, it holds the row, so a reader waits for the fold.
RSpec.describe Notifications::RowEvents, 'under a second connection', :ci_guard do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after { Prosopite.resume }

  let(:first_time) { Time.zone.local(2026, 11, 24, 14, 1, 0) }
  let(:created_time) { Time.zone.local(2026, 11, 24, 14, 1, 30) }
  let(:last_time) { Time.zone.local(2026, 11, 24, 14, 3, 0) }
  let(:event_time) { Time.zone.local(2026, 11, 24, 14, 4, 0) }

  # An unread row whose three times are apart, committed so the second
  # connection can read it.
  def create_row(organisation)
    ActsAsTenant.current_tenant = organisation
    project = create(:project, organisation: organisation)
    ticket = create(:ticket, organisation: organisation, project: project)
    create(:notification, recipient: create(:user), organisation: organisation, notifiable: ticket,
                          project: project, actor: create(:user), event_type: 'ticket_commented',
                          channel: 'in_app', state: 'queued', priority: 'normal', group_count: 1,
                          payload: { 'action' => 'commented', 'actor_ids' => [] },
                          created_at: created_time, updated_at: created_time,
                          first_event_at: first_time, last_event_at: last_time)
  end

  # Runs fold! on this connection with a short lock timeout, so a wait for the
  # row ends in ActiveRecord::LockWaitTimeout instead of a hang.
  def fold_with_lock_timeout(...)
    Notification.transaction do
      Notification.connection.execute("SET LOCAL lock_timeout = '100ms'")
      described_class.fold!(...)
    end
  end

  it 'waits for the connection that holds the row, then refuses the row it marked read' do
    organisation = create(:organisation)
    row = create_row(organisation)
    loaded = Notification.find(row.id)

    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) do
          Notification.transaction do
            held = Notification.lock.find(row.id)
            ready << true
            release.pop
            held.mark_as_read!
          end
        end
      end
    end
    Timeout.timeout(10) { ready.pop }

    # The holder is at the barrier. The bounded lock timeout proves fold! cannot
    # pass it, without relying on sleeps or on which thread runs faster.
    asked = []
    expect do
      fold_with_lock_timeout(notification: loaded, at: event_time) do |given|
        asked << given.state
        true
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(asked).to be_empty
    expect(Notification.find(row.id)).to have_attributes(state: 'queued', group_count: 1)

    release << true
    expect(holder.join(10)).to be_present
    holder.value

    expect(loaded).to have_attributes(state: 'queued', group_count: 1)
    answer = described_class.fold!(notification: loaded, at: event_time)

    expect(answer).to be(false)
    expect(Notification.find(row.id)).to have_attributes(state: 'read', group_count: 1,
                                                         first_event_at: first_time, last_event_at: last_time)
  ensure
    release << true if release
    holder&.join(2)
    holder&.kill if holder&.alive?
  end

  it 'holds the row while it asks the block, so a reader waits for the fold' do
    started_at = Time.current
    organisation = create(:organisation)
    row = create_row(organisation)

    asking = Queue.new
    answer_block = Queue.new
    folder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) do
          described_class.fold!(notification: Notification.find(row.id), at: event_time) do
            asking << true
            answer_block.pop
          end
        end
      end
    end
    Timeout.timeout(10) { asking.pop }

    # The fold is inside the block. A reader that marks the row read cannot
    # pass the lock until the fold commits.
    expect do
      Notification.transaction do
        Notification.connection.execute("SET LOCAL lock_timeout = '100ms'")
        Notification.find(row.id).mark_as_read!
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Notification.find(row.id)).to have_attributes(state: 'queued', group_count: 1)

    answer_block << true
    expect(folder.join(10)).to be_present
    expect(folder.value).to be(true)

    # The clock runs here: the fold stamped the row with the time of its write,
    # some moment of this example, long after the event's own time.
    Notification.find(row.id).mark_as_read!
    folded = Notification.find(row.id)
    expect(folded).to have_attributes(state: 'read', group_count: 2, first_event_at: first_time)
    expect(event_time).to be < started_at
    expect(folded.last_event_at).to be_between(started_at.floor(6), Time.current)
  ensure
    answer_block << true if answer_block
    folder&.join(2)
    folder&.kill if folder&.alive?
  end
end
