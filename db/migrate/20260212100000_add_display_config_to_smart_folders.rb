# frozen_string_literal: true

class AddDisplayConfigToSmartFolders < ActiveRecord::Migration[8.0]
  def change
    add_column :smart_folders, :display_columns, :jsonb, null: true
    # Format: { "table_columns": [...], "list_columns": {"cells": [...], "metadata": [...]}, "header_columns": [...] }

    add_column :smart_folders, :sort_column, :string, null: true
    add_column :smart_folders, :sort_direction, :string, null: true
    # sort_column: "created_at", "updated_at", "title", "number", etc.
    # sort_direction: "asc" or "desc"
    # Old sort_by field is NOT removed (rollback safety)
  end
end
