# frozen_string_literal: true

# T17 (doc/billing_agentur_konto_plan.md §17.3b): monthly AI consumption per
# organisation, aggregated onto the Account so it SURVIVES the deletion of that
# organisation. Today `organisations.has_many :ai_usages, dependent: :destroy`
# takes the entire consumption history with the org, and `ai_usages` carries no
# account_id -- the row does not know its billing level.
#
# Three deliberate schema properties, each of them load-bearing:
#
# 1. NO foreign key on organisation_id. The whole point is that the row outlives
#    the organisation; an FK would either cascade it away or block the delete.
#    organisation_name is the snapshot that keeps the row readable afterwards --
#    without it a post-deletion row is an anonymous UUID on an invoice.
# 2. bigint for the two counters. `ai_usages.credits_used`/`tokens_used` are
#    int4, and SUM(int4) is bigint in Postgres -- a monthly aggregate of a large
#    org would otherwise sit right under the int4 ceiling. cost_cents widens to
#    decimal(15,6) for the same reason: the source column (12,6) tops out at
#    ~10.000 EUR PER ROW, which is not a sane ceiling for a month.
# 3. The unique index is what makes rows write-once. Both writers use
#    insert_all(unique_by:) = ON CONFLICT DO NOTHING, so a re-run can only ever
#    FILL GAPS, never rewrite history. That matters because the aggregation
#    scope (AiUsage.quota_counted) joins ai_credentials, and a credential that
#    is later deleted (dependent: :nullify) or flipped to
#    included_in_quota: false would make a re-run silently write SMALLER numbers
#    over a period that was already settled.
class CreateAiUsageRollups < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_usage_rollups, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true, index: false

      # Provenance only -- deliberately NOT a reference/FK, see header.
      t.uuid :organisation_id, null: false
      t.string :organisation_name, null: false

      t.date :period_start, null: false

      t.bigint :credits_used, default: 0, null: false
      t.bigint :tokens_used, default: 0, null: false
      t.decimal :cost_cents, precision: 15, scale: 6, default: 0, null: false

      # True only for a period that was CUT SHORT by the organisation's
      # deletion. A reader must be able to tell "this month is a stub" from
      # "this month is settled" -- otherwise a partial final month looks like a
      # sudden drop in consumption.
      t.boolean :partial, default: false, null: false

      t.datetime :aggregated_at, null: false

      t.timestamps
    end

    add_index :ai_usage_rollups, %i[account_id organisation_id period_start],
              unique: true, name: 'idx_ai_usage_rollups_unique_period'
    # Read path: an account's history, newest first.
    add_index :ai_usage_rollups, %i[account_id period_start],
              name: 'idx_ai_usage_rollups_account_period'
  end
end
