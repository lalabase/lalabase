class AddDetailSettingsToViewConfigurations < ActiveRecord::Migration[8.0]
  def change
    add_column :view_configurations, :detail_settings, :jsonb, default: {}
  end
end
