# frozen_string_literal: true

# The merges of the people above the organisations: a group is one person's own note that
# rows of different organisations are the same human, an entry names one of those rows.
# Neither table carries a tenant: a group reaches over organisations and belongs to its
# owner alone. Neither holds a name or any other field of a person.
#
# The database holds what the two denormalised columns of an entry promise:
# * (person_group_id, owner_id) -> person_groups (id, owner_id): the owner of an entry is
#   the owner of its group;
# * (person_id, organisation_id) -> people (id, organisation_id): the organisation of an
#   entry is the organisation of the row it names;
# * exactly one address: the row (person_id), or a member's account (user_id) while that
#   member has no row;
# * one entry per owner and row, one per owner, organisation and account, and one source
#   per organisation in a group.
# A deleted row, organisation or group takes its entries along.
class CreatePersonGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :person_groups, id: :uuid do |t|
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.timestamps
      t.index %i[id owner_id], unique: true
    end

    create_table :person_group_entries, id: :uuid do |t|
      t.uuid :person_group_id, null: false
      t.uuid :owner_id, null: false
      t.uuid :organisation_id, null: false
      t.uuid :person_id
      t.uuid :user_id
      t.timestamps

      t.check_constraint 'num_nonnulls(person_id, user_id) = 1', name: 'person_group_entries_one_address'
      t.index %i[owner_id organisation_id person_id], unique: true, where: 'person_id IS NOT NULL',
                                                      name: 'index_person_group_entries_on_owner_and_person'
      t.index %i[owner_id organisation_id user_id], unique: true, where: 'user_id IS NOT NULL',
                                                    name: 'index_person_group_entries_on_owner_and_account'
      t.index %i[person_group_id organisation_id], unique: true,
                                                   name: 'index_person_group_entries_on_group_and_organisation'
      # The lines of one owner: every read of the list, every merge, split and release. The
      # two unique indexes above begin with the owner but are partial, so neither serves it.
      t.index :owner_id
      # For the cascades and for the rewrite when a member leaves.
      t.index %i[person_id organisation_id], name: 'index_person_group_entries_on_person'
      t.index %i[organisation_id user_id], name: 'index_person_group_entries_on_organisation_and_account'
      t.index :user_id
    end

    add_foreign_key :person_group_entries, :person_groups, column: %i[person_group_id owner_id],
                                                           primary_key: %i[id owner_id], on_delete: :cascade
    add_foreign_key :person_group_entries, :organisations, on_delete: :cascade
    add_foreign_key :person_group_entries, :people, column: %i[person_id organisation_id],
                                                    primary_key: %i[id organisation_id], on_delete: :cascade
    add_foreign_key :person_group_entries, :users
  end
end
