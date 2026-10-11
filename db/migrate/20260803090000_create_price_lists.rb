# frozen_string_literal: true

# Preisliste P1 (doc/billing_preisliste_rabatt_plan.md §4/D9): a price list is
# ONE published price level for a plan, valid from starts_on. The seat ladder
# itself lives in price_tiers -- list and tiers are published together in one
# transaction (D9), because a half-replaced level would be a price nobody
# decided on.
#
# The date window sits HERE and not on the tiers, so EffectiveDating keeps a
# single scope (plan_key) and the no-overlap check stays one-dimensional (D4
# review constraint). A tier inherits its window from its list.
#
# GLOBAL table: operator-curated pricing, not tenant data -- no acts_as_tenant
# (pattern: ai_packages). Deliberately reachable without a tenant, because the
# public pricing page renders it (D7).
#
# created_by_email is a STRING SNAPSHOT, not a foreign key (D8): the admin
# operator is a Beuser, not a User, and beusers have no soft-delete -- a
# nullifying FK would destroy the audit value exactly when it is needed.
class CreatePriceLists < ActiveRecord::Migration[8.0]
  def change
    create_table :price_lists, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :plan_key, null: false
      t.string :currency, null: false, default: 'EUR'
      t.date :starts_on, null: false
      # NULL = open-ended. ends_on is INCLUSIVE: the last day the list applies.
      t.date :ends_on
      t.string :note
      t.string :created_by_email

      t.timestamps
    end

    add_index :price_lists, %i[plan_key starts_on]
  end
end
