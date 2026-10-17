# frozen_string_literal: true

# The base view of "Alle Meetings" has no project: a view configuration with
# project_id NULL, one per user, organisation and view type. The unique index
# over (user_id, project_id, view_type) does not hold that row (Postgres counts
# NULLs as distinct), so it gets a partial index of its own. No data changes.
#
# One transaction, not a concurrent index: the table holds a few rows per user,
# and a rollback must leave nothing half done.
class AllowViewConfigurationsWithoutProject < ActiveRecord::Migration[8.1]
  INDEX = 'index_view_configs_on_user_organisation_type_without_project'

  def up
    change_column_null :view_configurations, :project_id, true
    add_index :view_configurations, %i[user_id organisation_id view_type],
              unique: true, where: 'project_id IS NULL', name: INDEX
  end

  # Refuses while a row without a project exists: the column cannot be NOT NULL
  # over it. Those rows are personal column lists of "Alle Meetings"; deleting
  # them costs their owners that list and nothing else.
  def down
    if select_value('SELECT 1 FROM view_configurations WHERE project_id IS NULL LIMIT 1')
      raise ActiveRecord::IrreversibleMigration,
            'view_configurations has rows without a project (base views of "Alle Meetings"). ' \
            'Delete them first: ViewConfiguration.where(project_id: nil).delete_all'
    end

    remove_index :view_configurations, name: INDEX
    change_column_null :view_configurations, :project_id, false
  end
end
