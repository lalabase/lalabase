class CreateViewConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :view_configurations, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.string :view_type, default: 'tickets'
      t.jsonb :table_columns, default: []
      t.jsonb :list_columns, default: []

      t.timestamps
    end

    add_index :view_configurations, [:user_id, :project_id, :view_type], unique: true, name: 'index_view_configs_on_user_project_type'
    add_index :view_configurations, :table_columns, using: :gin
    add_index :view_configurations, :list_columns, using: :gin
  end
end
