# frozen_string_literal: true

class CreateDashboardConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :dashboard_configurations, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.jsonb :layout, null: false, default: []
      t.timestamps
    end

    add_index :dashboard_configurations, [:user_id, :project_id],
              unique: true,
              name: 'idx_dashboard_config_user_project'

    add_index :dashboard_configurations, [:project_id],
              unique: true,
              where: 'user_id IS NULL',
              name: 'idx_dashboard_config_project_default'
  end
end
