# frozen_string_literal: true

class CreatePersonalAccessTokenProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :personal_access_token_projects, id: :uuid do |t|
      t.references :personal_access_token, type: :uuid, null: false, foreign_key: true, index: false
      t.references :project, type: :uuid, null: false, foreign_key: true

      t.timestamps

      t.index %i[personal_access_token_id project_id],
              unique: true,
              name: 'idx_pat_projects_uniq'
    end
  end
end
