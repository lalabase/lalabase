# frozen_string_literal: true

namespace :activities do
  # A data backfill (Lalabase::DataBackfills::TASKS). Until 2026-10-29
  # ProjectTrackable#track_member_added stored the member's login address in the
  # activity's parameters (`user_email`). Everyone who reads the project's
  # members area sees those rows, and the activity search read the whole JSON,
  # so it confirmed an address a member may now hide (User::EmailDisplay). This
  # removes the key from the old rows; other parameters stay. Idempotent: the
  # second run finds no row with the key.
  desc 'Remove the stored login address from old member_added activities (a data backfill)'
  task drop_member_emails: :environment do
    removed = ActsAsTenant.without_tenant do
      Activity.unscoped.where('parameters ? :key', key: 'user_email')
              .update_all(['parameters = parameters - :key', { key: 'user_email' }])
    end
    puts "activities:drop_member_emails: #{removed} activities cleaned."
  end
end
