# frozen_string_literal: true

# The subdomains organisations are shown under (doc/org_subdomains_plan.md, S1). One table
# for the current name and the names a change left behind: a row without held_until is
# the organisation's current subdomain, a row with it holds an old name for a while. A
# name is unique across both, so no organisation can take a held name, by an index and not
# only by a validation.
#
# The legacy columns organisations.subdomain and organisations.domain are not used: they
# were written without any check, and a value nobody chose for this must not become a
# host the day the feature is switched on.
class CreateOrganisationSubdomains < ActiveRecord::Migration[8.1]
  def change
    create_table :organisation_subdomains, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, index: false,
                                  foreign_key: { on_delete: :cascade }
      t.string :subdomain, null: false
      t.datetime :held_until
      t.timestamps
    end

    add_index :organisation_subdomains, :subdomain, unique: true
    add_index :organisation_subdomains, :organisation_id, unique: true, where: 'held_until IS NULL',
                                                          name: 'index_organisation_subdomains_one_current'
    add_index :organisation_subdomains, :organisation_id
  end
end
