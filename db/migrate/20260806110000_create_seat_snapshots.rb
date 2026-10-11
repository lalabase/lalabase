# frozen_string_literal: true

# The month-boundary seat state per account (M1a, doc/abrechnungsmodell_plan.md
# §4 step 1; T18 in doc/billing_agentur_konto_plan.md §17.3): who occupied a
# counted seat when the measurement month began. DERIVED from seat_events and
# recomputable at any time -- see the SeatSnapshot model for why this is the
# opposite of ai_usage_rollups' write-once rule.
class CreateSeatSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :seat_snapshots, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid, index: false

      # First day of the measurement month. The boundary it names is formed in
      # Europe/Berlin (A6), the date itself is zone-free.
      t.date :period_start, null: false

      # ok | not_reconstructible | failed (Subscriptions::Constants). A missing
      # row is none of the three: it is a GAP, and hunting gaps is the M1b
      # watcher's job. So none of the three may ever double as "absent".
      t.string :status, null: false

      # Only set on ok: the number of DISTINCT users across the pairs (D4.1).
      # NULL on the other two states -- a zero there would be a lie (§3).
      t.integer :seat_count

      # The occupied (organisation, user) pairs at the boundary, each entry
      # carrying organisation_id, organisation_name and user_id. The map, not
      # just a number: replaying a month on a count alone is the plus/minus
      # counter §4 forbids, and the frozen name keeps the row readable after
      # the organisation is deleted (§5).
      t.jsonb :pairs, null: false, default: []

      # Only set on failed (T18 point 3: the failure becomes a row).
      t.string :error

      t.datetime :computed_at, null: false
      t.timestamps
    end

    # One row per account and boundary (17.3 point 1) -- also what makes the
    # writer's overwrite-on-rerun race-safe.
    add_index :seat_snapshots, %i[account_id period_start], unique: true,
                                                            name: 'idx_seat_snapshots_unique_period'
    # For the M1b gap question "which accounts have no row for period X": the
    # unique index leads with account_id and cannot serve a lookup by period
    # alone.
    add_index :seat_snapshots, :period_start
  end
end
