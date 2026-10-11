# frozen_string_literal: true

# Explicit guest-vs-internal flag instead of deriving it from the scope (plan
# doc/billing_agentur_konto_plan.md §5). Default true: new roles are
# billable until an agency deliberately sets a customer/guest role to false.
class AddBillableToRoles < ActiveRecord::Migration[8.0]
  def change
    add_column :roles, :billable, :boolean, null: false, default: true
  end
end
