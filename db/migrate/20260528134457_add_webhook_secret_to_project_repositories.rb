class AddWebhookSecretToProjectRepositories < ActiveRecord::Migration[8.0]
  def change
    # Encrypted at the model layer (`encrypts :webhook_secret`). Nullable so
    # existing repos don't need a backfill migration — the secret is generated
    # lazily (before_create for new repos, ensure_webhook_secret! for old ones).
    add_column :project_repositories, :webhook_secret, :text
  end
end
