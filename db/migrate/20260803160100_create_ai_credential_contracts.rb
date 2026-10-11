# frozen_string_literal: true

# The ASSESSED version of what a provider promises about customer content
# (doc/ki_vertragsdaten_plan.md § 4). Separate from the documents, because
# evidence and conclusion age independently: a new PDF does not change the
# assessment, and an assessment can change while the paper stays the same.
#
# Uses EffectiveDating (third caller after PriceList and AccountDiscount): two
# assessed versions of one credential may NOT overlap -- unlike the documents,
# where overlap is legitimate. "What did we state on date X" must have exactly
# one answer.
#
# Every axis defaults to its UNSPECIFIED variant: a credential nobody has
# assessed must not assert a promise. The customer card shows that state as its
# own grey badge rather than hiding it, because a missing statement reads as
# reassurance.
class CreateAiCredentialContracts < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_credential_contracts, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :ai_credential, type: :uuid, null: false, foreign_key: true, index: false

      t.string :training_usage, null: false, default: 'unspecified'
      t.string :retention_policy, null: false, default: 'unspecified'
      # Only meaningful for retention_policy 'limited' (OpenAI: 30 days).
      t.integer :retention_days
      t.string :subprocessors_disclosure, null: false, default: 'unspecified'
      t.text :subprocessors
      # Internal reasoning: why this assessment, what was decisive.
      t.text :note
      t.string :recorded_by_email

      t.date :starts_on, null: false
      # NULL = still current.
      t.date :ends_on

      t.timestamps
    end

    add_index :ai_credential_contracts, %i[ai_credential_id starts_on]

    # Which documents support this assessment. A join table rather than a column,
    # because the relation runs both ways: one paper supports several statements,
    # and one statement rests on several papers.
    #
    # The link is document <-> version, NOT document <-> axis. Which paper
    # supports which of the three axes is carried informally by the document's
    # locator and summary -- an axis column here would triple the upkeep on every
    # new version for a mapping that changes only when a provider restructures
    # its documents.
    create_table :ai_credential_contract_documents, id: :uuid,
                                                    default: -> { 'gen_random_uuid()' } do |t|
      t.references :ai_credential_contract, type: :uuid, null: false, foreign_key: true, index: false
      t.references :ai_credential_document, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end

    add_index :ai_credential_contract_documents,
              %i[ai_credential_contract_id ai_credential_document_id],
              unique: true, name: 'idx_contract_documents_unique_pair'
  end
end
