class RemoveStatusPriorityFromViewConfigurations < ActiveRecord::Migration[8.0]
  def up
    # Update existing ViewConfigurations to remove 'status' and 'priority' from columns
    # Use unscoped to bypass ActsAsTenant
    ViewConfiguration.unscoped.find_each do |config|
      # Remove from table_columns
      if config.table_columns.present?
        config.table_columns = config.table_columns - ['status', 'priority']
      end
      
      # Remove from list_columns
      if config.list_columns.present?
        config.list_columns = config.list_columns - ['status', 'priority']
      end
      
      # Remove from header_columns
      if config.header_columns.present?
        config.header_columns = config.header_columns - ['status', 'priority']
      end
      
      # Use update_column to bypass validations and callbacks
      config.update_columns(
        table_columns: config.table_columns,
        list_columns: config.list_columns,
        header_columns: config.header_columns
      )
    end
  end
  
  def down
    # Restore default columns with status and priority
    # Use unscoped to bypass ActsAsTenant
    ViewConfiguration.unscoped.find_each do |config|
      if config.view_type == 'tickets'
        # Add back to table_columns if not present
        table_cols = config.table_columns || []
        table_cols = (['number', 'title', 'status', 'priority'] + table_cols).uniq
        
        # Add back to list_columns if not present
        list_cols = config.list_columns || []
        list_cols = (['number', 'title', 'status', 'priority'] + list_cols).uniq
        
        # Add back to header_columns if not present
        header_cols = config.header_columns || []
        header_cols = (['status', 'priority'] + header_cols).uniq
        
        # Use update_columns to bypass validations and callbacks
        config.update_columns(
          table_columns: table_cols,
          list_columns: list_cols,
          header_columns: header_cols
        )
      end
    end
  end
end
