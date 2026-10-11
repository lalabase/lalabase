# frozen_string_literal: true

# W3 of doc/billing_rechnungsstellung_r1_plan.md (E2): the billing state of an
# account is THREE COLUMNS, not a Subscription model.
#
# Under R1 (invoice-based billing, the payment happens outside the application)
# there is exactly one lifecycle state. A Subscription model would be an empty
# shell carrying a single value, and it would be re-cut anyway the day a payment
# provider arrives and brings its own period and status. Three columns say
# everything the billing list needs: from when, how often, and how long the
# customer has to pay.
#
# The booked price rung is deliberately NOT stored: it follows from the seat
# count via Subscriptions::PriceLookup#tier_for on the reference date. Storing it
# would create a second truth next to the price list and require something to
# keep the two in sync -- and under R1 there is no such trigger.
class AddBillingStateToAccounts < ActiveRecord::Migration[8.0]
  def change
    change_table :accounts, bulk: true do |t|
      # NULL means "not billed (yet)". Deliberately NOT the same as "free
      # forever", which is expressed as a 100 % AccountDiscount (plan E4): an
      # account nobody has decided about and an account decided to be free must
      # not look identical, or the forgotten one disappears from the billing
      # list without anyone noticing.
      t.column :billing_starts_on, :date

      # Values come from Subscriptions::Constants::BILLING_INTERVAL_KEYS, but the
      # literal is written here ON PURPOSE, not the constant: a migration has to
      # replay from a bare checkout years from now, and referencing app code
      # makes `db:migrate` from zero die with NameError once that constant is
      # renamed or moved. No other migration in this repo reads app code either.
      # The literal must stay in step with INTERVAL_MONTHLY; the agreement is
      # pinned by spec/models/billing_interval_default_guard_spec.rb, which is in
      # the curated CI list in .github/workflows/guards.yml. Deliberately NOT the
      # model spec, which checks the same thing but runs in neither CI job.
      t.column :billing_interval, :string, null: false, default: 'monthly'

      # Days granted on the invoice before the payment is late. § 7 of the terms
      # says fees are due IN ADVANCE for the billing period and names no payment
      # window, so this is a commercial decision rather than something derived
      # from the contract (plan § 15, open point 2).
      t.column :payment_terms_days, :integer, null: false, default: 14

      # Serves the billing list's "due on this date" query, and the "unclear"
      # section reads the NULLs.
      t.index :billing_starts_on
    end
  end
end
