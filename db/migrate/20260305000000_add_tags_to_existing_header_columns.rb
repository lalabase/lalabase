# frozen_string_literal: true

class AddTagsToExistingHeaderColumns < ActiveRecord::Migration[8.0]
  def up
    # Backfill: add 'tags' to existing ViewConfigurations that don't have it
    execute <<~SQL
      UPDATE view_configurations
      SET header_columns = header_columns || '["tags"]'::jsonb
      WHERE header_columns IS NOT NULL
        AND NOT header_columns @> '"tags"'::jsonb
    SQL
  end

  def down
    # No-op: removing tags from header_columns would be destructive
  end
end
