class AddIndexesToTicketsCustomAttributes < ActiveRecord::Migration[8.0]
  def up
    # GIN index for JSONB search in custom_attributes
    add_index :tickets, :custom_attributes, using: :gin, if_not_exists: true

    # B-tree index for frequent existence checks
    execute <<-SQL
      CREATE INDEX IF NOT EXISTS index_tickets_on_custom_attrs_not_null
      ON tickets ((custom_attributes IS NOT NULL))
      WHERE custom_attributes IS NOT NULL;
    SQL
    
    # Functional indexes for performance-critical fields can be added later:
    # execute <<-SQL
    #   CREATE INDEX IF NOT EXISTS index_tickets_on_custom_attr_story_points
    #   ON tickets ((custom_attributes->>'story_points'))
    #   WHERE custom_attributes->>'story_points' IS NOT NULL;
    # SQL
  end
  
  def down
    remove_index :tickets, name: :index_tickets_on_custom_attrs_not_null, if_exists: true
    remove_index :tickets, :custom_attributes, using: :gin, if_exists: true
  end
end
