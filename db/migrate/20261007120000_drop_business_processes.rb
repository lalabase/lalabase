# frozen_string_literal: true

# Prozesse left before the core went public (October 2026): slice 1a had put
# its tables and a rights column on main, but no screen ever shipped. Step 1
# (#972) removed the code and parked the column in ignored_columns; this drops
# what is left. Production held no rows. if_exists: a fresh installation loads
# db/schema.rb and never had these tables, and the migration that created them
# is no longer in the repository.
class DropBusinessProcesses < ActiveRecord::Migration[8.1]
  def up
    drop_table :process_steps, if_exists: true
    drop_table :business_processes, if_exists: true
    remove_column :project_permissions, :processes_access, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Prozesse comes back as a feature of its own, with its own migration'
  end
end
