# frozen_string_literal: true

# The base view of "Alle Meetings" has no project: a view configuration with
# project_id NULL, one per user, organisation and view type. The unique index
# over (user_id, project_id, view_type) does not hold that row (Postgres counts
# NULLs as distinct), so it gets a partial index of its own. No data changes.
#
# Rolling back fails while a row without a project exists (the column cannot
# be NOT NULL again over it). Those rows are personal column lists of the
# overview; delete them first: ViewConfiguration.where(project_id: nil).delete_all
class AllowViewConfigurationsWithoutProject < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = 'index_view_configs_on_user_organisation_type_without_project'

  def change
    change_column_null :view_configurations, :project_id, true
    add_index :view_configurations, %i[user_id organisation_id view_type],
              unique: true, where: 'project_id IS NULL', name: INDEX, algorithm: :concurrently
  end
end
