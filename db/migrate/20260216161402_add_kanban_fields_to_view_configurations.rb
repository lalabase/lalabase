class AddKanbanFieldsToViewConfigurations < ActiveRecord::Migration[8.0]
  def change
    add_column :view_configurations, :view_mode, :string, default: 'table'
    add_column :view_configurations, :kanban_attribute_definition_id, :uuid

    add_foreign_key :view_configurations, :ticket_attribute_definitions,
                    column: :kanban_attribute_definition_id, on_delete: :nullify
  end
end
