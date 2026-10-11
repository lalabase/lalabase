# frozen_string_literal: true

# Preisliste P1 (doc/billing_preisliste_rabatt_plan.md §4/D3): a percentage
# discount granted to one account for a period, editable ONLY in the internal
# admin backend -- same class of special condition as accounts.guest_max_*.
#
# Rows instead of three columns on accounts, because a discount is worth money:
# who granted whom what, when and why has to stay reconstructable AFTER it
# expired, and discounts follow one another (trial 100% -> early adopter 30% ->
# regular). Overwriting columns would lose exactly that.
#
# Exactly ONE active discount per account -- no stacking, no multiplying
# percentages. Enforced by the same no-overlap rule as price lists
# (EffectiveDating, scope :account_id). That rule is also what keeps the two
# planned conditions (founding customers / new founders, §12.3) mutually
# exclusive without any extra logic.
#
# granted_by_email is a STRING SNAPSHOT, not a foreign key -- see
# CreatePriceLists (D8: the admin operator is a Beuser, not a User).
class CreateAccountDiscounts < ActiveRecord::Migration[8.0]
  def change
    create_table :account_discounts, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :percent_off, null: false
      t.date :starts_on, null: false
      # NULL = open-ended. Legitimate for early-customer commitments, but the
      # admin list flags it -- a forgotten permanent discount is the most
      # expensive mistake in this feature (D3).
      t.date :ends_on
      t.string :reason
      t.string :granted_by_email

      t.timestamps
    end

    # Covers the account_id lookup by leftmost prefix (t.references above runs
    # with index: false), and serves the "active on date" query.
    add_index :account_discounts, %i[account_id starts_on]
  end
end
