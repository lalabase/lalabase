# frozen_string_literal: true

# Queue liveness for the AI area's "Indexierung" page: the second half of a backlog
# figure, which alone cannot say whether anyone is working through it.
module Embeddings
  # Is anything actually WORKING on the indexing backlog right now?
  #
  # Embeddings::IndexHealth answers "how much is outstanding", and its Result#working?
  # reads a positive pending count with no failures as healthy progress. That inference
  # only holds while a job worker exists. Without one the two states are indistinguishable
  # on the page: content queued a minute ago and content queued in February both render as
  # "wird verarbeitet", and the admin is told to wait for something nobody is doing. That
  # is the false reassurance this object exists to remove — a backlog needs a worker before
  # "pending" means progress.
  #
  # Deliberately NOT folded into IndexHealth: that class has a documented query budget on
  # the AI hub (≤ 9 own queries for the whole page, doc/ki_bereich_navigation_plan.md §3.3),
  # and this question belongs to the Indexierung page, which has room for one more read.
  #
  # Tenant-free ON PURPOSE, and it must stay that way: solid_queue_processes carries no
  # organisation, so this may only ever answer the SYSTEM question "is the queue being
  # served". It must never grow a per-organisation count off those tables — job rows are
  # not tenant-scoped, and a count taken from them would put another tenant's backlog on
  # this tenant's page.
  class IndexingPipeline
    # Solid Queue workers write a heartbeat every few seconds. The grace window has to sit
    # far enough above that interval that a slow beat is never read as a dead worker, and
    # far enough below "a human notices" that a real outage surfaces on the next page load.
    HEARTBEAT_GRACE = 5.minutes

    # The row kind a Solid Queue worker registers under. Dispatcher, scheduler and
    # supervisor rows exist too and do NOT execute jobs, so a supervisor alone (a
    # half-started `bin/dev`) must not read as a healthy pipeline.
    WORKER_KIND = 'Worker'

    Result = Struct.new(:worker_alive, keyword_init: true) do
      # Named for what the READER has to decide, not for the column: a page asking
      # "should I tell the admin that nothing is moving" should not have to negate.
      def stalled?
        !worker_alive
      end
    end

    def self.call
      new.call
    end

    def call
      Result.new(worker_alive: worker_alive?)
    end

    private

    # Rescued, not asserted: this is a status read on a page that must render even when
    # the queue tables are unavailable (a separate database in this app — config/database.yml
    # points the queue at its own connection). An unreachable queue is itself a stall, so
    # the failure answers the question rather than raising past it.
    def worker_alive?
      SolidQueue::Process
        .where(kind: WORKER_KIND)
        .where(last_heartbeat_at: HEARTBEAT_GRACE.ago..)
        .exists?
    rescue StandardError => e
      Rails.logger.warn("#{self.class}: queue liveness unreadable (#{e.class}: #{e.message}) — " \
                        'reporting the pipeline as stalled.')
      false
    end
  end
end
