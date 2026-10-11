# frozen_string_literal: true

# Nullable by design (D3/D8, CLAUDE.md "Lange Locks vermeiden"): existing
# organisations get backfilled via Account.backfill_all! (T4, lib/tasks/accounts.rake)
# and new ones via Organisation#ensure_account (T3) before this column becomes
# NOT NULL in a later, separate migration.
class AddAccountIdToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_reference :organisations, :account, type: :uuid, null: true, foreign_key: true
  end
end
