# frozen_string_literal: true

# The plan an account is billed on (doc/billing_preisliste_rabatt_plan.md §13).
# Every existing account stays on 'cloud', the price it pays today; a constant
# default adds the column without rewriting the table.
class AddPlanKeyToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :plan_key, :string, default: 'cloud', null: false
  end
end
