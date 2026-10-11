# frozen_string_literal: true

# The persona pool for the project-aware chat (Plan §6.1). Two-layered:
# global rows (organisation_id NULL — the seeded, operator-curated defaults)
# plus optional per-org rows. Deliberately NOT a standard acts_as_tenant table,
# because the global rows must be visible across every tenant.
class CreatePromptPersonas < ActiveRecord::Migration[8.0]
  def change
    create_table :prompt_personas, id: :uuid do |t|
      # NULL = global default pool; set = org-owned override/addition.
      # index: false — the table stays tiny (a handful of personas) and the
      # two partial unique indexes below already cover every lookup we make.
      t.references :organisation, type: :uuid, null: true,
                                  foreign_key: true, index: false
      t.string  :key,              null: false
      t.jsonb   :labels,           null: false, default: {} # { "de" => "…", "en" => "…" }
      t.jsonb   :prompt_fragments, null: false, default: {} # intent text per locale
      t.integer :position,         null: false, default: 0
      t.boolean :active,           null: false, default: true
      t.boolean :system,           null: false, default: false # global defaults: not per-org deletable

      t.timestamps
    end

    # Two PARTIAL unique indexes, not one composite [organisation_id, key].
    # Postgres treats NULLs as DISTINCT in a unique index, so a plain unique
    # [organisation_id, key] would happily allow TWO global rows to share a key
    # (both organisation_id IS NULL). Split the guarantee in two:
    #   - global rows : key unique on its own            (organisation_id IS NULL)
    #   - per-org rows: [organisation_id, key] unique     (organisation_id IS NOT NULL)
    add_index :prompt_personas, :key, unique: true,
                                      where: 'organisation_id IS NULL',
                                      name: 'index_prompt_personas_on_global_key'
    add_index :prompt_personas, %i[organisation_id key], unique: true,
                                                         where: 'organisation_id IS NOT NULL',
                                                         name: 'index_prompt_personas_on_org_and_key'
  end
end
