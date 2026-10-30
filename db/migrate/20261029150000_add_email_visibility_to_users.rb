# frozen_string_literal: true

# Which email the others see of a member (User::EmailDisplay): the login
# address (default, what everyone saw before), a separate contact address, or
# none. The check constraint is the second line behind the model validation.
# A constant default on a new column is a metadata-only change in PostgreSQL,
# so the users table is not rewritten.
class AddEmailVisibilityToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :email_visibility, null: false, default: 'login'
      t.string :contact_email
      t.check_constraint "email_visibility IN ('login', 'contact', 'none')", name: 'users_email_visibility_known'
    end
  end
end
