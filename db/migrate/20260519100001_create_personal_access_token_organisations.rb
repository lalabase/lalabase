# frozen_string_literal: true

class CreatePersonalAccessTokenOrganisations < ActiveRecord::Migration[8.0]
  def change
    create_table :personal_access_token_organisations, id: :uuid do |t|
      t.references :personal_access_token, type: :uuid, null: false, foreign_key: true, index: false
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.boolean :all_projects, null: false, default: true

      t.timestamps

      t.index %i[personal_access_token_id organisation_id],
              unique: true,
              name: 'idx_pat_orgs_uniq'
    end
  end
end
