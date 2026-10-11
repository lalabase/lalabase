# frozen_string_literal: true

class RemoveAttributeGroupsLayer < ActiveRecord::Migration[8.0]
  def up
    # Step 1: Add project_id to ticket_attribute_definitions
    add_reference :ticket_attribute_definitions, :project, type: :uuid, foreign_key: true

    # Step 2: Migrate data - copy project_id from attribute_group → project relationship
    execute <<-SQL.squish
      UPDATE ticket_attribute_definitions tad
      SET project_id = p.id
      FROM projects p
      WHERE p.attribute_group_id = tad.attribute_group_id
    SQL

    # Step 3: Delete orphaned definitions (attribute groups without a project)
    execute 'DELETE FROM ticket_attribute_definitions WHERE project_id IS NULL'

    # Step 4: Make project_id NOT NULL
    change_column_null :ticket_attribute_definitions, :project_id, false

    # Step 5: Remove old foreign key references
    remove_reference :ticket_attribute_definitions, :attribute_group
    remove_reference :projects, :attribute_group

    # Step 6: Drop the attribute_groups table
    drop_table :attribute_groups

    # Step 7: Add new indexes
    add_index :ticket_attribute_definitions, %i[project_id name], unique: true
    add_index :ticket_attribute_definitions, %i[project_id active]
  end

  def down
    # Recreate attribute_groups table
    create_table :attribute_groups, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :icon
      t.string :color
      t.boolean :active, default: true
      t.boolean :system, default: false
      t.integer :position, default: 0
      t.jsonb :settings
      t.timestamps
    end

    add_index :attribute_groups, %i[organisation_id name], unique: true
    add_index :attribute_groups, %i[organisation_id active]
    add_index :attribute_groups, :position

    # Add attribute_group_id back to projects
    add_reference :projects, :attribute_group, type: :uuid, foreign_key: true
    add_index :projects, %i[organisation_id attribute_group_id]

    # Remove new indexes
    remove_index :ticket_attribute_definitions, %i[project_id name]
    remove_index :ticket_attribute_definitions, %i[project_id active]

    # Add attribute_group_id back to ticket_attribute_definitions
    add_reference :ticket_attribute_definitions, :attribute_group, type: :uuid, foreign_key: true

    # Create one attribute_group per project that has definitions
    execute <<-SQL.squish
      INSERT INTO attribute_groups (id, organisation_id, name, created_at, updated_at)
      SELECT gen_random_uuid(), p.organisation_id, p.name, NOW(), NOW()
      FROM projects p
      INNER JOIN ticket_attribute_definitions tad ON tad.project_id = p.id
      GROUP BY p.id, p.organisation_id, p.name
    SQL

    # Link projects to their new attribute_groups
    execute <<-SQL.squish
      UPDATE projects p
      SET attribute_group_id = ag.id
      FROM attribute_groups ag
      WHERE ag.name = p.name AND ag.organisation_id = p.organisation_id
    SQL

    # Link ticket_attribute_definitions to attribute_groups via project
    execute <<-SQL.squish
      UPDATE ticket_attribute_definitions tad
      SET attribute_group_id = p.attribute_group_id
      FROM projects p
      WHERE p.id = tad.project_id
    SQL

    # Remove project_id from ticket_attribute_definitions
    remove_reference :ticket_attribute_definitions, :project

    # Add back old indexes
    add_index :ticket_attribute_definitions, %i[attribute_group_id name], unique: true
    add_index :ticket_attribute_definitions, %i[attribute_group_id active]
  end
end
