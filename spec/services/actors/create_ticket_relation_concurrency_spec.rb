# frozen_string_literal: true

require 'rails_helper'

# Two writers at the same time (doc/ticket_relations_plan.md, revision 4, §3.2 and §12). Each
# would find no cycle on its own and together they would close one. The advisory lock per
# organisation in Actors::CreateTicketRelation makes the second writer wait until the first
# has committed, and then its cycle check sees the first edge.
#
# Two real database connections and committed data: a spy would only prove that the lock is
# called. The first writer is held right after its cycle check, inside its transaction; the
# second must then be seen WAITING on an advisory lock. Without the lock it would not wait,
# and both writes would go through.
RSpec.describe 'Concurrent ticket relations' do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  def tickets(count)
    ActsAsTenant.with_tenant(organisation) do
      projects = create_list(:project, 2, organisation: organisation)
      Array.new(count) { |index| create(:ticket, project: projects[index % 2]) }
    end
  end

  def link_in_thread(source, target)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) do
          Actors::CreateTicketRelation.call(ticket: source, other_ticket: target, kind: 'blocks', current_user: user)
        end
      end
    end
  end

  # Holds the first caller of the cycle check after its answer, until `release` is fed.
  def hold_first_cycle_check(ready, release)
    calls = 0
    mutex = Mutex.new
    allow(Tickets::CycleCheck).to receive(:call).and_wrap_original do |original, **arguments|
      answer = original.call(**arguments)
      if mutex.synchronize { (calls += 1) == 1 }
        ready << true
        release.pop
      end
      answer
    end
  end

  def waits_on_advisory_lock?(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM pg_stat_activity
        WHERE wait_event_type = 'Lock' AND wait_event = 'advisory' AND datname = current_database()
      SQL
      return true if waiting.positive?
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def race(first_edge, second_edge)
    ready = Queue.new
    release = Queue.new
    hold_first_cycle_check(ready, release)
    first = link_in_thread(*first_edge)
    Timeout.timeout(10) { ready.pop }
    second = link_in_thread(*second_edge)
    waited = waits_on_advisory_lock?
    release << true
    [waited, [first, second].map { |thread| thread.join(10)&.value }]
  ensure
    release << true
    [first, second].compact.each { |thread| thread.join(2) || thread.kill }
  end

  def relation_pairs
    ActsAsTenant.with_tenant(organisation) { TicketRelation.pluck(:source_ticket_id, :target_ticket_id) }
  end

  it 'lets exactly one of A -> B and B -> A through' do
    a, b = tickets(2)

    waited, (first, second) = race([a, b], [b, a])

    expect(waited).to be(true)
    expect(first).to be_success
    expect(second).not_to be_success
    expect(second.code).to eq(:cycle)
    expect(relation_pairs).to eq([[a.id, b.id]])
  end

  it 'lets exactly one of two edges through that share no ticket but close a ring of four' do
    a, b, c, d = tickets(4)
    ActsAsTenant.with_tenant(organisation) do
      TicketRelation.create!(source_ticket: b, target_ticket: c, relation_type: :blocks)
      TicketRelation.create!(source_ticket: d, target_ticket: a, relation_type: :precedes)
    end

    waited, (first, second) = race([a, b], [c, d])

    expect(waited).to be(true)
    expect(first).to be_success
    expect(second.code).to eq(:cycle)
    expect(relation_pairs).to contain_exactly([b.id, c.id], [d.id, a.id], [a.id, b.id])
  end
end
