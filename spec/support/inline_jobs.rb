# frozen_string_literal: true

# Runs the jobs of a block instead of handing them to Solid Queue, the
# adapter the test environment is configured with.
#
# with_delivered_mails: needed since the confirmation mail is sent via
# deliver_later (User#send_devise_notification): a spec that reads the subject
# or link of this mail needs it delivered.
#
# ⚠️ Only the mail jobs. The :inline adapter would be simpler and wrong: it also
# runs jobs immediately that are deliberately set in the future, and
# `OutboxConsumeJob.set(wait_until:)` breaks under it.
module InlineJobs
  # Holds the jobs a block enqueues on the test adapter, so the example can run
  # them afterwards (drain_enqueued_jobs, perform_enqueued_jobs).
  def with_test_queue_adapter
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def with_delivered_mails(&)
    with_test_queue_adapter do
      perform_enqueued_jobs(only: ->(job) { job.is_a?(ActionMailer::MailDeliveryJob) }, &)
    end
  end

  # Runs every enqueued job, and the jobs those enqueue, until the queue is
  # empty. Each runs from its serialized form, so it gets the tenant it was
  # enqueued with and nothing else, as in the worker. Call it outside any
  # tenant block: an ambient without_tenant would lift the requirement the
  # worker trips over. A job that keeps retrying fails the example instead of
  # looping. Returns the number of jobs performed.
  def drain_enqueued_jobs(max_rounds: 10)
    performed = 0
    max_rounds.times do
      count = perform_enqueued_jobs
      return performed if count.zero?

      performed += count
    end
    raise "jobs still enqueued after #{max_rounds} rounds: #{enqueued_jobs.map { |job| job[:job] }.tally}"
  end
end

RSpec.configure do |config|
  config.include InlineJobs
end
