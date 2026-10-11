# frozen_string_literal: true

# Billing account above organisation (plan doc/billing_agentur_konto_plan.md D2).
# Account stays a pure billing identity, organisation stays unchanged as workspace/tenant.
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts, id: :uuid do |t|
      t.string :name, null: false
      t.string :billing_email
      t.references :owner, type: :uuid, null: true, index: true,
                           foreign_key: { to_table: :users,
                                          on_delete: :nullify }
      # Guest ceiling (§4.3): limits configurable per account, maintainable only internally
      # (admin backend), not by the account owner themselves.
      t.integer :guest_max_organisations, null: false, default: 1
      t.integer :guest_max_projects_per_organisation, null: false, default: 1
      t.timestamps
    end
  end
end
