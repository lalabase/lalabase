# frozen_string_literal: true

# GDPR opt-in gate for AI features (audit 2026-07-03, item 1.2): AI processing
# must be explicitly enabled per organisation by an org admin. No backfill on
# purpose — existing organisations opt in once, so every activation has an
# auditable actor + timestamp.
class AddAiOptInToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :ai_enabled, :boolean, null: false, default: false
    add_column :organisations, :ai_activated_at, :datetime
    add_reference :organisations, :ai_activated_by, type: :uuid,
                                                    foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
