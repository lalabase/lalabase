# frozen_string_literal: true

require 'rails_helper'

# The bulk action locks rows in several organisations. Two of them, and a bulk
# action next to an action on a single row, must wait for each other and never
# deadlock: every caller takes the organisations in the order of their ids and
# the rows of one organisation by ONE statement in id order
# (Notifications::SubjectBundle).
RSpec.describe Actors::ChangeNotificationStates, 'concurrent actions', type: :service do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  let(:user) { create(:user) }

  def organisation_with_ticket_rows(count: 2)
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      make_token_owner_a_member(user, organisation, projects: [project])
      ticket = create(:ticket, project: project)
      rows = Array.new(count) do
        create(:notification, recipient: user, organisation: organisation, project: project,
                              notifiable: ticket, channel: 'in_app', state: :delivered)
      end
      [organisation, rows]
    end
  end

  # Lets the thread marked :hold_after_lock stop right after its first lock,
  # with the lock held, until `release` is fed.
  def hold_first_lock(held, release)
    allow(Notifications::SubjectBundle).to receive(:lock).and_wrap_original do |original, **kwargs|
      locked = original.call(**kwargs)
      if Thread.current[:hold_after_lock]
        Thread.current[:hold_after_lock] = false
        held << true
        release.pop
      end
      locked
    end
  end

  def in_thread(hold: false, pid: nil)
    Thread.new do
      Thread.current[:hold_after_lock] = hold
      Prosopite.pause
      ActiveRecord::Base.connection_pool.with_connection do
        pid << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()') if pid
        yield
      end
    rescue ActiveRecord::Deadlocked => e
      e
    end
  end

  def wait_for_lock(pid)
    sql = ActiveRecord::Base.sanitize_sql_array(["SELECT count(*) FROM pg_stat_activity WHERE pid = ? AND wait_event_type = 'Lock'", pid])
    Timeout.timeout(10) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value(sql).to_i.positive?
    end
  end

  def states(rows)
    ActsAsTenant.without_tenant { Notification.where(id: rows.map(&:id)).order(:id).pluck(:state) }
  end

  it 'serializes two selections that name the same organisations in opposite order' do
    (first_org, first_rows), (second_org, second_rows) =
      [organisation_with_ticket_rows, organisation_with_ticket_rows].sort_by { |organisation, _rows| organisation.id }
    ActsAsTenant.current_tenant = nil
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    hold_first_lock(held, release)

    first = in_thread(hold: true) do
      described_class.call(ids_by_organisation: { first_org => [first_rows.first.id], second_org => [second_rows.first.id] },
                           change: 'archive', current_user: user)
    end
    Timeout.timeout(10) { held.pop }
    second = in_thread(pid: second_pid) do
      described_class.call(ids_by_organisation: { second_org => [second_rows.last.id], first_org => [first_rows.last.id] },
                           change: 'read', current_user: user)
    end
    wait_for_lock(Timeout.timeout(10) { second_pid.pop })
    release << true
    results = Timeout.timeout(10) { [first.value, second.value] }

    expect(results.grep(Exception)).to be_empty
    expect(results).to all(be_success)
    # The archive ran first and took both bundles whole; nothing was left to read.
    expect(states(first_rows + second_rows)).to all(eq('archived'))
  ensure
    release&.push(true)
    [first, second].compact.each { |thread| thread.join(2) || thread.kill }
  end

  it 'waits for an action on a single row of a selected bundle, and the other way round' do
    organisation, rows = organisation_with_ticket_rows
    ActsAsTenant.current_tenant = nil
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    hold_first_lock(held, release)

    first = in_thread(hold: true) do
      described_class.call(ids_by_organisation: { organisation => [rows.first.id] }, change: 'read', current_user: user)
    end
    Timeout.timeout(10) { held.pop }
    second = in_thread(pid: second_pid) do
      ActsAsTenant.with_tenant(organisation) do
        Actors::ChangeNotificationState.call(notification: rows.last, change: 'archive', current_user: user)
      end
    end
    wait_for_lock(Timeout.timeout(10) { second_pid.pop })
    release << true
    results = Timeout.timeout(10) { [first.value, second.value] }

    expect(results.grep(Exception)).to be_empty
    expect(results).to all(be_success)
    expect(states(rows)).to all(eq('archived'))
  ensure
    release&.push(true)
    [first, second].compact.each { |thread| thread.join(2) || thread.kill }
  end
end
