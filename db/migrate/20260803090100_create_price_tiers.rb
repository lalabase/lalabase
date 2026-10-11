# frozen_string_literal: true

# Preisliste P1 (doc/billing_preisliste_rabatt_plan.md §4/V4): one rung of the
# seat ladder, per billing interval. A table instead of columns so a further
# rung or a third interval is a row, not a migration (D10).
#
# Amount formula, exactly one reading (§4):
#
#   amount = base_amount_cents + per_seat_amount_cents * seats
#
# per_seat multiplies ALL seats, not just those above min_seats -- otherwise
# the open-ended rung (11+, 10 EUR per seat) would bill 10 EUR at 11 seats
# instead of 110 EUR. Rungs 1..10 carry a pure base amount (per_seat 0), the
# open rung carries base 0 + per_seat. That field pair is also Stripe's tier
# model (flat_amount + unit_amount), so the later hand-over is a mapping.
#
# Amounts are always PER BILLING PERIOD -- the monthly amount for 'monthly',
# the YEARLY amount for 'yearly' (27840, not 2320). The monthly equivalent
# shown in the UI is computed, never stored: storing it would multiply a
# rounding error twelvefold into the invoice.
#
# The two ladder invariants (gapless, non-overlapping seat ranges) are checked
# when a list is PUBLISHED, not per row -- a row can never see its siblings,
# and a ladder under construction would never satisfy them (§4).
class CreatePriceTiers < ActiveRecord::Migration[8.0]
  def change
    create_table :price_tiers, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :price_list, type: :uuid, null: false, foreign_key: true, index: false
      t.string :billing_interval, null: false
      t.integer :min_seats, null: false
      # NULL = open-ended rung (the last one, e.g. "11 and up").
      t.integer :max_seats
      t.integer :base_amount_cents, null: false, default: 0
      t.integer :per_seat_amount_cents, null: false, default: 0

      t.timestamps
    end

    # Also covers the price_list_id lookup by leftmost prefix, which is why
    # t.references runs with index: false above.
    add_index :price_tiers, %i[price_list_id billing_interval min_seats],
              unique: true, name: 'idx_price_tiers_unique_rung_per_list'
  end
end
