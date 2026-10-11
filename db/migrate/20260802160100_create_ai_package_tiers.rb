# frozen_string_literal: true

# KI-Pakete P1 (doc/ki_pakete_plan.md §6, E2/E3): the performance ladder of a
# package. Two rows per package today (fast/thorough, E2) — a table instead of
# two columns so a third tier is a row, not a migration (E3). The unique index
# on (ai_package_id, key) is what makes "the org's chosen tier" addressable by
# key from organisations later (P2/P3).
#
# chat_credential FK WITHOUT on_delete (NO ACTION) — same reasoning as
# ai_packages.embedding_credential_id: the DB blocks deleting an advertised
# credential. Tiers themselves die with their package via dependent: :destroy
# (model), so no cascade here (house default).
class CreateAiPackageTiers < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_package_tiers, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :ai_package, type: :uuid, null: false, foreign_key: true, index: false
      t.string :key, null: false
      t.string :label, null: false
      t.references :chat_credential, type: :uuid, foreign_key: { to_table: :ai_credentials }
      t.string :chat_model
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :ai_package_tiers, %i[ai_package_id key], unique: true,
                                                        name: 'idx_ai_package_tiers_unique_key_per_package'
  end
end
