class CreateAiUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_usages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.references :ai_credential, null: true, foreign_key: true, type: :uuid
      t.string :provider, null: false
      t.string :model_used
      t.integer :tokens_used, default: 0
      t.integer :cost_cents, default: 0
      t.timestamp :used_at
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :ai_usages, [:organisation_id, :used_at]
    add_index :ai_usages, [:provider, :used_at]

  end
end