# frozen_string_literal: true

namespace :activities do
  # A data backfill (Lalabase::DataBackfills::TASKS). Until 2026-10-29
  # ProjectTrackable#track_member_added stored the member's login address in the
  # activity's parameters (`user_email`), and Notifications::FanoutService and
  # OutboxEvent copied those parameters into their payload. Everyone who reads
  # the project's members area saw the rows, the activity search and the inbox
  # search read the JSON, and REST/MCP hand the notification payload out: an
  # address a member may now hide (User::EmailDisplay). This removes the key
  # from all three; other keys stay. Both or neither, in one transaction, as
  # Posts::ExcerptRedaction does for comment excerpts. Idempotent: the second
  # run finds no row with the key.
  desc 'Remove the stored login address from old member_added activities and their copies (a data backfill)'
  task drop_member_emails: :environment do
    copied = "payload->'parameters' ? 'user_email'"
    removed = ActsAsTenant.without_tenant do
      ActiveRecord::Base.transaction do
        # key = 'project.member_added' first: the (organisation_id, key, created_at)
        # index narrows the rows before the JSON is read.
        count = Activity.unscoped.where(key: 'project.member_added').where("parameters ? 'user_email'")
                        .update_all("parameters = parameters - 'user_email'")
        Notification.unscoped.where(copied).update_all("payload = payload #- '{parameters,user_email}'")
        OutboxEvent.unscoped.where(copied).update_all("payload = payload #- '{parameters,user_email}'")
        count
      end
    end
    puts "activities:drop_member_emails: #{removed} activities cleaned."
  end
end
