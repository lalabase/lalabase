# frozen_string_literal: true

# Solid Queue configuration for notification system
Rails.application.configure do
  # Only configure if Solid Queue is the active job adapter
  if config.active_job.queue_adapter == :solid_queue
    # Configure Solid Queue
    config.solid_queue.connects_to = { database: { writing: :primary } }

    # Silence polling logs in development and test
    config.solid_queue.silence_polling = Rails.env.development? || Rails.env.test?

    # Set SolidQueue log level to reduce verbosity
    config.solid_queue.logger = Rails.logger
    config.solid_queue.silence_polling = true if Rails.env.development?
  end
end

# REMOVED (KI-Pakete P4d): an after_initialize block used to class_eval its own
# SolidQueue::Job#concurrency_key over the framework's. It did not add a rule — it
# DISABLED the mechanism, app-wide.
#
# Solid Queue stores the key an ActiveJob computes in solid_queue_jobs.concurrency_key
# and then reads it back through that method. Shadowing the attribute reader made every
# row answer nil, so #concurrency_limited? was false for every job ever enqueued and no
# semaphore was ever taken — every `limits_concurrency` declaration in this app was
# silently inert. Measured, not inferred: the column held the right key while the method
# returned nil for the same row.
#
# Its own two rules never worked either, for three independent reasons: the first line
# guarded on `respond_to?(:job_class)`, which is FALSE because Solid Queue declares
# job_class private; the case compared that (a Class) against String literals; and
# NotificationFanoutJob does not exist in this repo. Removing it therefore changes no
# behaviour that ever happened — it only stops suppressing the framework's.
#
# If per-recipient throttling of EmailDeliveryJob is genuinely wanted, it belongs on the
# job as `limits_concurrency key: ->(notification_id) { ... }`, and it needs a spec that
# asserts a duplicate is actually discarded — the missing piece that let this rot
# unnoticed. Pinned by spec/jobs/solid_queue_concurrency_spec.rb.
