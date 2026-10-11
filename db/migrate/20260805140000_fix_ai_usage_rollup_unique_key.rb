# frozen_string_literal: true

# T17 review finding F2: the unique key included account_id, which defeats the
# write-once property it was supposed to guarantee.
#
# A rollup row states a fact about an ORGANISATION and a MONTH: "this org
# consumed X in July". The Account is where that fact gets BOOKED, not part of
# its identity. With account_id in the key, an organisation moved to a different
# Account would pass the conflict check on a re-run and insert a SECOND row for
# the same period -- the old row stays, and the month is counted on both
# accounts. Measured on the merged code: 2 rows, 20 credits for 10 credits of
# real consumption. The monthly job re-checks six months on every run, so a
# re-run is a standing path, not an exotic case.
#
# There is no organisation-move path in the app today, which is exactly why this
# is the right moment: the table is empty in every environment (production is
# still on 20260803170000 and has never seen the table), so the swap costs
# nothing. After the first backfill it would be a data migration.
#
# account_id stays on the row as payload -- it records where the period WAS
# booked, and a settled period keeps its original account even if the
# organisation moves later. That is the intended behaviour, and with this key it
# is also the enforced one.
class FixAiUsageRollupUniqueKey < ActiveRecord::Migration[8.0]
  def change
    remove_index :ai_usage_rollups,
                 column: %i[account_id organisation_id period_start],
                 unique: true, name: 'idx_ai_usage_rollups_unique_period'

    add_index :ai_usage_rollups, %i[organisation_id period_start],
              unique: true, name: 'idx_ai_usage_rollups_unique_period'
  end
end
