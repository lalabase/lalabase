# frozen_string_literal: true

# Log out everywhere (doc/org_subdomains_plan.md, S3): every host has a session of its own,
# and a cookie session cannot be revoked one by one. The number goes into a session at
# sign-in and is compared on every request; signing out raises it.
class AddSessionVersionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :session_version, :integer, null: false, default: 0
  end
end
