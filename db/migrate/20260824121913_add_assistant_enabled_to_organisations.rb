# frozen_string_literal: true

# S3a (§13-2, operator level): the org-wide assistant gets its OWN per-org flag,
# deliberately separate from project_chat_enabled -- an organisation may keep the
# project chat without getting the org-wide assistant. Flipped in the admin
# backend (beuser-gated), like the project-chat beta flag next to it.
class AddAssistantEnabledToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :assistant_enabled, :boolean, default: false, null: false
  end
end
