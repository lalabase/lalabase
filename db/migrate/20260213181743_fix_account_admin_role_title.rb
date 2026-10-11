# frozen_string_literal: true

class FixAccountAdminRoleTitle < ActiveRecord::Migration[8.0]
  def up
    execute "UPDATE roles SET title = 'account_admin' WHERE title = 'Account Admin'"
  end

  def down
    execute "UPDATE roles SET title = 'Account Admin' WHERE title = 'account_admin'"
  end
end
