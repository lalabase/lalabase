# frozen_string_literal: true

module Meetings
  # Generates the AI ticket suggestions for a meeting off the request path.
  # Tenant-safe from birth (the Task 0 pattern): Solid Queue dequeues with NO
  # ambient tenant, so load the meeting without one, then run the service inside its
  # organisation so acts_as_tenant scoping (Fragment matching, suggestion writes)
  # holds. Mirrors Meetings::SummaryJob / EmbeddingProcessingJob.
  class TicketSuggestionJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound do |_job, error|
      Rails.logger.warn("Meetings::TicketSuggestionJob discarded: #{error.message}")
    end

    # Keep enqueue failures on the durable run, so the composer can offer retry.
    def self.enqueue_run(run:)
      job = new(meeting_id: run.meeting_id)
      job.job_id = run.job_id
      raise ActiveJob::EnqueueError, 'enqueue failed' unless job.enqueue
    rescue StandardError => e
      Rails.logger.error("Ticket suggestions enqueue: #{e.class}")
      run.mark_failed!(from: ['queued'])
    end

    def perform(meeting_id:)
      meeting = ActsAsTenant.without_tenant { Meeting.find(meeting_id) }

      ActsAsTenant.with_tenant(meeting.organisation) do
        run = MeetingTicketSuggestionRun.find_by(meeting: meeting, job_id: job_id)
        if run
          with_execution_lock(run) do
            run.reload
            if run.running?
              # No live process holds the execution lock. A previous provider call
              # may already have been billed: offer an explicit retry immediately.
              interrupt(run)
            elsif run.queued?
              claimed = MeetingTicketSuggestionRun.where(id: run.id, status: :queued).update_all(status: 'running', updated_at: Time.current)
              Meetings::TicketSuggestionService.call(meeting: meeting, run: run.reload) if claimed == 1
            end
          ensure
            interrupt(run) if run.reload.running?
          end
        elsif instance_of?(TicketSuggestionJob) && !MeetingTicketSuggestionRun.where(meeting: meeting).exists?
          # Already queued pre-migration jobs retain their original signature.
          # A legacy delivery must never replace a newer, explicitly bound result.
          Meetings::TicketSuggestionService.call(meeting: meeting)
        else
          clear_abandoned_flag(meeting)
        end
      end
    rescue ActiveRecord::RecordNotFound => e
      raise unless meeting

      clear_abandoned_flag(meeting)
      Rails.logger.warn("Meetings::TicketSuggestionJob discarded: #{e.message}")
    end

    private

    def with_execution_lock(run)
      key = Digest::SHA256.hexdigest("meeting-ticket-run:#{run.id}")[0, 15].to_i(16)
      MeetingTicketSuggestionRun.connection_pool.with_connection do |connection|
        acquired = connection.select_value(MeetingTicketSuggestionRun.sanitize_sql_array(['SELECT pg_try_advisory_lock(?)', key]))
        next unless acquired

        begin
          yield
        ensure
          connection.select_value(MeetingTicketSuggestionRun.sanitize_sql_array(['SELECT pg_advisory_unlock(?)', key]))
        end
      end
    end

    def interrupt(run)
      run.mark_failed!(from: ['running'])
    end

    def clear_abandoned_flag(meeting)
      ActsAsTenant.with_tenant(meeting.organisation) do
        meeting.with_lock do
          meeting.update!(suggestions_creation_flag: false) unless MeetingTicketSuggestionRun.where(meeting: meeting, status: %w[queued running]).exists?
        end
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
