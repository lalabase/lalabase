# frozen_string_literal: true

# What: Unit spec for Embeddings::IndexingPipeline — "is anything serving the backlog?"
# Type: Service spec against real solid_queue_processes rows.
# Why (philosophy): This object exists to remove ONE false statement from the Indexierung
#   page. Embeddings::IndexHealth#working? reads "pending > 0, failed == 0" as progress,
#   which is true only while a job worker exists. With none, content queued months ago and
#   content queued a minute ago render identically as "Verarbeitung läuft", and the admin
#   waits for work nobody is doing — the exact shape that hid 25 EmbeddingProcessingJobs
#   sitting untouched since February. So the tests that matter are the boundary of the
#   heartbeat window and the KIND filter: a supervisor row is not a worker, and treating
#   it as one would restore the same false green on a half-started `bin/dev`.
# Contract: .call returns a Result whose #stalled? is true unless a row of kind 'Worker'
#   has beaten within HEARTBEAT_GRACE. Never raises — an unreadable queue IS a stall.

require 'rails_helper'

RSpec.describe Embeddings::IndexingPipeline do
  # The boundary examples below need a STOPPED clock, and finding that out is the point:
  # written against the wall clock, "exactly on the boundary" wrote its row a few hundred
  # microseconds before the service recomputed the cutoff, so the row was already older
  # than the window and the example failed. That is drift in the TEST, not a bug in the
  # window — but it means an un-frozen boundary test never actually stands ON the boundary,
  # and the inclusive edge would have gone unproven either way it was written.
  include ActiveSupport::Testing::TimeHelpers

  def register(kind:, heartbeat:, name: "#{kind}-#{SecureRandom.hex(4)}")
    SolidQueue::Process.create!(kind: kind, last_heartbeat_at: heartbeat, pid: rand(1..30_000), name: name)
  end

  before { SolidQueue::Process.delete_all }

  describe 'the heartbeat window' do
    # n-1 / n / n+1 around HEARTBEAT_GRACE. The window is the whole judgement: too tight
    # and a slow beat reads as an outage, too loose and a dead queue looks alive for as
    # long as the grace lasts.
    it 'counts a worker one second INSIDE the boundary as alive' do
      freeze_time do
        register(kind: 'Worker', heartbeat: described_class::HEARTBEAT_GRACE.ago + 1.second)

        expect(described_class.call.stalled?).to be(false)
      end
    end

    it 'counts a worker beating exactly ON the boundary as alive (inclusive)' do
      freeze_time do
        register(kind: 'Worker', heartbeat: described_class::HEARTBEAT_GRACE.ago)

        expect(described_class.call.stalled?).to be(false)
      end
    end

    it 'reports a stall one second OUTSIDE the boundary' do
      freeze_time do
        register(kind: 'Worker', heartbeat: described_class::HEARTBEAT_GRACE.ago - 1.second)

        expect(described_class.call.stalled?).to be(true)
      end
    end
  end

  describe 'which rows count as a worker' do
    # A supervisor registers without executing a single job. `bin/dev` that came up far
    # enough to register but not far enough to run work is exactly the state this page is
    # supposed to expose, so it must not satisfy the check.
    it 'does NOT accept a supervisor as a worker' do
      register(kind: 'Supervisor', heartbeat: Time.current)

      expect(described_class.call.stalled?).to be(true)
    end

    it 'does NOT accept a dispatcher or scheduler as a worker' do
      register(kind: 'Dispatcher', heartbeat: Time.current)
      register(kind: 'Scheduler', heartbeat: Time.current)

      expect(described_class.call.stalled?).to be(true)
    end

    it 'accepts a live worker standing next to stale rows of every other kind' do
      register(kind: 'Supervisor', heartbeat: 1.hour.ago)
      register(kind: 'Worker', heartbeat: 3.hours.ago)
      register(kind: 'Worker', heartbeat: 10.seconds.ago)

      expect(described_class.call.stalled?).to be(false)
    end
  end

  describe 'with nothing registered at all' do
    it 'reports a stall (the state a machine with no bin/dev is in)' do
      expect(described_class.call.stalled?).to be(true)
    end
  end

  describe 'when the queue tables cannot be read' do
    # Fail TOWARDS the warning. This runs on a status page whose whole job is to report
    # trouble; a 500 here would take away the one screen that could have explained it.
    it 'reports a stall instead of raising' do
      allow(SolidQueue::Process).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'queue gone')

      expect { described_class.call }.not_to raise_error
      expect(described_class.call.stalled?).to be(true)
    end
  end

  describe 'Result#stalled?' do
    it 'is the negation of worker_alive, so a reader never has to negate' do
      expect(described_class::Result.new(worker_alive: true).stalled?).to be(false)
      expect(described_class::Result.new(worker_alive: false).stalled?).to be(true)
    end
  end
end
