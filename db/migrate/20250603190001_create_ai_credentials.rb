class CreateAiCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :provider, null: false, default: 'openai'
      t.text :access_token, null: false
      t.string :organization_id
      t.string :default_model
      t.boolean :active, default: false
      t.boolean :enabled, default: true
      t.json :additional_config, default: {}
      t.text :description

      t.timestamps
    end

    add_index :ai_credentials, :provider
    add_index :ai_credentials, :active
    add_index :ai_credentials, [:provider, :active], unique: true, where: "active = true"
    add_index :ai_credentials, :enabled
  end
end