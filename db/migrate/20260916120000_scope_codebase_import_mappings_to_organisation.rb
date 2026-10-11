# frozen_string_literal: true

# A Codebase import mapping belongs to the organisation that imported. Without
# the column a second organisation importing the same export resolved the first
# one's tickets, billing groups and users, skipped its tickets as "already
# imported" and even deleted the first one's ticket mappings as stale.
#
# The column stays nullable: existing rows are assigned afterwards by
# `bin/rails codebase_import:scope_mappings` (a data task, not part of this
# schema change). A row without an organisation is invisible to the tenant
# scope, so nothing reads it in the meantime.
class ScopeCodebaseImportMappingsToOrganisation < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  NEW_INDEX = 'index_codebase_import_mappings_on_organisation_and_codebase_id'
  OLD_INDEX = 'index_codebase_import_mappings_on_codebase_id_and_entity_type'

  def up
    add_column :codebase_import_mappings, :organisation_id, :uuid
    add_foreign_key :codebase_import_mappings, :organisations, validate: false
    validate_foreign_key :codebase_import_mappings, :organisations
    add_index :codebase_import_mappings, %i[organisation_id codebase_id entity_type],
              unique: true, name: NEW_INDEX, algorithm: :concurrently
    # Unique per organisation now; the same Codebase id may exist in several.
    remove_index :codebase_import_mappings, name: OLD_INDEX, algorithm: :concurrently
  end

  # Fails on purpose once two organisations mapped the same Codebase id: the
  # global uniqueness cannot come back without losing one of them.
  def down
    add_index :codebase_import_mappings, %i[codebase_id entity_type],
              unique: true, name: OLD_INDEX, algorithm: :concurrently
    remove_index :codebase_import_mappings, name: NEW_INDEX, algorithm: :concurrently
    remove_foreign_key :codebase_import_mappings, :organisations
    remove_column :codebase_import_mappings, :organisation_id
  end
end
