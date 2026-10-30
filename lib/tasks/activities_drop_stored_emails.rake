# frozen_string_literal: true

namespace :activities do
  # A data backfill (Lalabase::DataBackfills::TASKS). Older activities stored a
  # member's login address in their parameters (Activity::STORED_EMAIL_KEYS:
  # project.member_added until 2026-10-29, ticket.assigned/unassigned before
  # they read the user from `secondary`), and Notifications::FanoutService and
  # OutboxEvent copied those parameters into their payload (an assignee
  # notification also at its top). Readers of the project saw the rows, the
  # activity and inbox searches read the JSON, and REST/MCP hand activity
  # parameters and notification payloads out: an address a member may now hide
  # (User::EmailDisplay). This removes the keys from all of them; other keys
  # stay. Both or neither, in one transaction, as Posts::ExcerptRedaction does
  # for comment excerpts. Idempotent: the second run finds no row with a key.
  #
  # Cost: `?|` on activities.parameters and on the nested payload has no index,
  # so each run reads activities, notifications and outbox_events once; the
  # top-level payload check can use the notifications GIN index.
  desc 'Remove stored login addresses from old activities and their copies (a data backfill)'
  task drop_stored_emails: :environment do
    keys = Activity::STORED_EMAIL_KEYS
    array = "ARRAY[#{keys.map { |key| ActiveRecord::Base.connection.quote(key) }.join(', ')}]::text[]"
    nested = "payload->'parameters' ?| #{array}"
    strip_nested = "jsonb_set(payload, '{parameters}', (payload->'parameters') - #{array})"

    removed = ActsAsTenant.without_tenant do
      ActiveRecord::Base.transaction do
        count = Activity.unscoped.where("parameters ?| #{array}").update_all("parameters = parameters - #{array}")
        Notification.unscoped.where("payload ?| #{array}").update_all("payload = payload - #{array}")
        Notification.unscoped.where(nested).update_all("payload = #{strip_nested}")
        OutboxEvent.unscoped.where(nested).update_all("payload = #{strip_nested}")
        count
      end
    end
    puts "activities:drop_stored_emails: #{removed} activities cleaned."
  end
end
