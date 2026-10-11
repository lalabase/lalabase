# frozen_string_literal: true

# Per-organisation beta gate for the project-aware chat feature (M10, D3).
# Default false → the feature is off for every org until an operator explicitly
# enables it per org (per Rails console during the beta; admin UI toggle deferred).
# `organisations` is a small table and PG 11+ adds a defaulted column without a
# rewrite, so a single add_column is safe here (no separate backfill needed).
class AddProjectChatEnabledToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :project_chat_enabled, :boolean, default: false, null: false
  end
end
