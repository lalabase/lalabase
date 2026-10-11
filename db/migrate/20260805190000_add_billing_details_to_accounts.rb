# frozen_string_literal: true

# B1 of doc/billing_stammdaten_plan.md: the invoice master data lives on the
# ACCOUNT, not on the organisation (E1). An agency bundling five client orgs
# would otherwise have five competing billing addresses, which is the same
# multiple-counting error the Account level was introduced to prevent.
#
# Flat columns instead of a BillingProfile (E2): the Account IS the billing
# entity, so there is nothing to normalise away, and no `&.` handling leaks into
# views and policies. The one argument for a separate object -- reuse for the
# later invoice snapshot -- does not hold: an issued invoice must carry the
# address as a FROZEN COPY, so a later address change cannot rewrite old
# invoices. That is a snapshot question, solved on `invoices`, not here.
#
# Every column is nullable at the database level. The requirement exists only in
# the :billing validation context (E3), because existing accounts (1:1 backfill,
# ensure_account callback, factories) have no billing data and must stay valid.
#
# No index on any address field: there is no query over them. The one foreign
# key is business_confirmed_by_id, nullify on delete -- who confirmed is an
# audit fact, and losing the user must not take the confirmation with it.
class AddBillingDetailsToAccounts < ActiveRecord::Migration[8.0]
  def change
    change_table :accounts, bulk: true do |t|
      # Legal company name. Deliberately NOT Account#name, which is a display
      # name auto-filled from the organisation name by the backfill.
      t.string :billing_name
      t.string :billing_addressee
      # Street and house number in ONE field: more robust internationally than
      # splitting them, and the split buys nothing we need.
      t.string :billing_street
      t.string :billing_street_2
      # string, never integer: leading zeros, UK and NL formats.
      t.string :billing_postal_code
      t.string :billing_city
      # Required only for countries where Stripe Tax needs a subdivision.
      t.string :billing_region
      t.string :billing_country, limit: 2
      t.string :billing_email_cc
      # Free text that ends up on the invoice: PO number, cost centre.
      t.string :billing_reference

      t.string :vat_id
      t.string :vat_id_status, default: 'unchecked'
      t.datetime :vat_id_checked_at
      # The company name VIES reported back. Kept as evidence and to detect a
      # mismatch against billing_name.
      t.string :vat_id_checked_name

      # E8: set at checkout in the Stripe phase, not here. WHO confirmed
      # matters because the owner can change via claim!, and WHICH WORDING was
      # confirmed matters because a timestamp without the text is worth little
      # in a dispute.
      t.datetime :business_confirmed_at
      t.uuid :business_confirmed_by_id
      t.string :business_confirmation_version
    end

    add_foreign_key :accounts, :users, column: :business_confirmed_by_id, on_delete: :nullify
    # Indexed like owner_id, its sibling foreign key: the nullify pass on a user
    # delete and every reverse lookup would otherwise scan. The effect is small
    # today because users are never hard-deleted here, but an unexplained
    # asymmetry between two foreign keys on one table costs more than the index.
    add_index :accounts, :business_confirmed_by_id
  end
end
