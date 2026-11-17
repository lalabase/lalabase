# frozen_string_literal: true

# A unique index on people (id, organisation_id): the target of a composite foreign key.
# A table that names a person together with its organisation (person_group_entries) can
# then let the database hold the two together: the organisation it stores is the
# organisation of the row. id alone is unique already, so the index refuses nothing.
# Built concurrently: people is read on every page of the directory.
class AddIdOrganisationIndexToPeople < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :people, %i[id organisation_id], unique: true, algorithm: :concurrently, if_not_exists: true,
                                               name: 'index_people_on_id_and_organisation_id'
  end
end
