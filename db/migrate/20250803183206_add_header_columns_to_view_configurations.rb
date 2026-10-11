class AddHeaderColumnsToViewConfigurations < ActiveRecord::Migration[8.0]
  def change
    add_column :view_configurations, :header_columns, :jsonb, default: []
    add_index :view_configurations, :header_columns, using: :gin
  end
end
