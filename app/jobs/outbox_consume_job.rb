# frozen_string_literal: true

# The OutboxConsumeJob processes OutboxEvents into notifications.
#
# PURPOSE:
# This job is triggered when an OutboxEvent is created.
# It takes the event, figures out who should be notified
# and creates the corresponding notifications.
#
# WHY BUILT THIS WAY:
# - Solid Queue instead of Sidekiq for better DB integration
# - Retry mechanism with exponential backoff
# - Concurrency control prevents duplicate processing
# - Multi-tenancy through acts_as_tenant
#
# EXAMPLE:
# Activity "ticket.commented" → OutboxEvent → OutboxConsumeJob
# → finds all relevant users → creates notifications

class OutboxConsumeJob < ApplicationJob
  queue_as :notifications

  # Retry with exponential backoff
  retry_on StandardError, wait: 10.seconds, attempts: 5

  # Don't retry certain errors immediately
  discard_on ActiveRecord::RecordNotFound

  def perform(outbox_event_id)
    # Loaded without a tenant: a job only carries the tenant that was set when
    # it was enqueued, and a signup enqueues with none (it runs entirely in
    # without_tenant).
    outbox_event = ActsAsTenant.without_tenant { OutboxEvent.find(outbox_event_id) }

    # Set tenant context from the outbox event
    ActsAsTenant.with_tenant(outbox_event.organisation) do
      # Process the event (this calls NotificationFanoutService)
      result = outbox_event.process!

      if result.is_a?(Hash) && !result[:success]
        # If processing failed, let the retry mechanism handle it
        raise StandardError, result[:error]
      end

      Rails.logger.debug "Successfully processed outbox event #{outbox_event_id}"
    end
  end
end
