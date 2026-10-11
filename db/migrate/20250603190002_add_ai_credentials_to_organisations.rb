class AddAiCredentialsToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :ai_access_token, :text
    add_column :organisations, :ai_organization_id, :string
    add_column :organisations, :ai_provider, :string, default: 'openai'

    add_index :organisations, :ai_provider
  end
end