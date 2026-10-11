# frozen_string_literal: true

# KI-Pakete P1 (doc/ki_pakete_plan.md §6, §7b.1): a curated provider bundle —
# one jurisdiction + one FIXED embedding triple (credential, model, dims — E11)
# + a ladder of chat tiers (separate table, E3). Global table: packages are
# operator-curated offerings, not tenant data — no organisation_id, no
# acts_as_tenant, no Admin:: twin model (pattern: prompt_personas).
#
# Most columns are DB-nullable on purpose: presence is a MODEL rule scoped to
# kind 'curated' (a future seeds-only 'custom' row carries no embedding fields,
# plan §7b.1 "kind ist kein Formularfeld").
#
# FK to ai_credentials deliberately WITHOUT on_delete (NO ACTION): a package
# ADVERTISES a credential, so the database must block deleting a referenced
# credential — the last line of defence behind the shared destroy-protection
# concern (plan §7b.2 "Löschen"). Contrast embedding_spaces.ai_credential_id
# (nullify), which merely REMEMBERS one.
class CreateAiPackages < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_packages, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :kind, null: false, default: 'curated'
      t.string :name, null: false
      t.text :description
      t.string :jurisdiction
      t.string :processing_region
      t.text :provider_note
      t.references :embedding_credential, type: :uuid, foreign_key: { to_table: :ai_credentials }
      t.string :embedding_model
      t.integer :embedding_dims
      # "Veröffentlicht (im Kundenkatalog sichtbar)" — NOT the credentials'
      # "Standard" semantics; deliberately labelled differently in the UI (§7b.1).
      t.boolean :active, null: false, default: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end
  end
end
