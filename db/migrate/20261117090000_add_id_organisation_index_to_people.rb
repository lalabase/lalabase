# frozen_string_literal: true

# A unique index on people (id, organisation_id): the target of a composite foreign key.
# A table that names a person together with its organisation (person_group_entries) can
# then let the database hold the two together: the organisation it stores is the
# organisation of the row. id alone is unique already, so the index refuses nothing.
# Built concurrently: people is read on every page of the directory.
#
# A concurrent build that breaks off leaves an INVALID index under this name, and
# if_not_exists takes it for the index: the next run would skip the build, and the
# foreign key of the next migration hangs on exactly this index. So what is left of a
# broken build goes first (the rule of the ANN indexes of content_embeddings).
class AddIdOrganisationIndexToPeople < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  NAME = 'index_people_on_id_and_organisation_id'

  def up
    drop_if_invalid
    add_index :people, %i[id organisation_id], unique: true, algorithm: :concurrently, if_not_exists: true, name: NAME
  end

  def down
    remove_index :people, name: NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def drop_if_invalid
    invalid = select_value(<<~SQL.squish)
      SELECT NOT i.indisvalid FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = #{quote(NAME)} AND n.nspname = ANY (current_schemas(false))
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(NAME)}") if invalid
  end
end
