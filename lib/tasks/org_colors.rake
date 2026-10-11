# frozen_string_literal: true

namespace :org_colors do
  # One-time backfill: assigns automatic recognition colors to existing users with
  # >=2 orgs (new users/reactivations run through the membership hooks).
  # Idempotent — OFF and already-set colors remain untouched. Only run once
  # the feature is complete (otherwise sidebars get colored before chip/line exist).
  # Logic in User::OrgColorSettings.backfill_all! (tested there); the task is just a wrapper.
  desc 'Backfill: automatische Org-Erkennungsfarben fuer bestehende Multi-Org-User'
  task backfill: :environment do
    count = User::OrgColorSettings.backfill_all!
    puts "org_colors:backfill — #{count} User aktualisiert."
  end
end
