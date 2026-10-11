# frozen_string_literal: true

class CreateProjectRepositories < ActiveRecord::Migration[8.0]
  def change
    create_table :project_repositories, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_repo_id, null: false
      t.string :full_name, null: false
      t.string :default_branch, null: false
      t.text :access_token, null: false
      t.references :connected_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.datetime :connected_at, null: false

      t.timestamps
    end

    add_index :project_repositories, %i[provider provider_repo_id organisation_id], unique: true,
                                                                                    name: 'idx_project_repositories_provider_repo_uniq'
  end
end
