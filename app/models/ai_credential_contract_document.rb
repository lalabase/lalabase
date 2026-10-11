# frozen_string_literal: true

# Which document supports which assessed version
# (doc/ki_vertragsdaten_plan.md § 4). A join table rather than a column, because
# the relation runs both ways: one paper supports several statements, and one
# statement rests on several papers.
class AiCredentialContractDocument < ApplicationRecord
  belongs_to :ai_credential_contract, inverse_of: :contract_documents
  belongs_to :ai_credential_document, inverse_of: :contract_documents

  validates :ai_credential_document_id, uniqueness: { scope: :ai_credential_contract_id }
end
