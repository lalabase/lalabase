# frozen_string_literal: true

# One VERSION of one contractual document of a provider
# (doc/ki_vertragsdaten_plan.md § 4). Google alone has three such papers --
# Service Specific Terms, CDPA and the Vertex data-governance documentation --
# and none of them covers everything: the training restriction sits in the SST,
# the retention details in the data-governance doc, the sub-processors in the
# CDPA.
#
# EIN Datensatz = EINE Fassung. A revised SST in November is a new row, not an
# edit of the old one, so a claim made in March stays traceable to the paper it
# rested on.
#
# Deliberately WITHOUT EffectiveDating, unlike the assessed contract versions:
# two versions of the same paper may legitimately overlap (the provider
# publishes the new one while the old still governs existing agreements), so the
# concern's no-overlap rule would be plainly wrong here. valid_from is a
# property of the paper, not an exclusive validity window.
class CreateAiCredentialDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_credential_documents, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :ai_credential, type: :uuid, null: false, foreign_key: true, index: false

      # Stable key of the DOCUMENT across its versions ('sst', 'cdpa', …).
      # Normalised in the model; without it a typo splits one paper's history in
      # two, and the operator sees two half-histories instead of one.
      t.string :document_key, null: false
      t.string :title, null: false
      t.text :summary
      t.string :url
      # Where exactly the statement sits: "Abschnitt Generative AI, Training
      # Restriction" or "Ziffer 5.2". Without it a 60-page PDF is worthless as
      # evidence -- nobody reads it a second time.
      t.string :locator
      t.text :body
      t.date :valid_from, null: false
      t.string :added_by_email

      t.timestamps
    end

    # Unique per (credential, paper, date): two versions of the same paper on
    # the same day would make "the current version" ambiguous.
    add_index :ai_credential_documents, %i[ai_credential_id document_key valid_from],
              unique: true, name: 'idx_credential_documents_unique_version'
  end
end
