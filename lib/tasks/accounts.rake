# frozen_string_literal: true

namespace :accounts do
  # One-time backfill: gives every organisation without an account_id (created
  # before the Organisation#ensure_account callback, T3) its own 1:1 Account.
  # Idempotent — a second run finds zero matching organisations.
  # Logic in Account.backfill_all! (tested there); the task is just a wrapper.
  desc 'Backfill: 1:1 Account fuer bestehende Organisationen ohne account_id'
  task backfill: :environment do
    count = Account.backfill_all!
    puts "accounts:backfill — #{count} Organisation(en) aktualisiert."
  end
end
