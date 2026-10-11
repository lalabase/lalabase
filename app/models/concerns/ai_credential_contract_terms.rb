# frozen_string_literal: true

# The provider's contractual documents and the assessed versions built on them
# (doc/ki_vertragsdaten_plan.md § 4/§ 5).
#
# A SHARED concern for the same reason as AiCredentialPricing and
# AiCredentialProviderRules: the admin backend edits through
# Admin::AiCredential, a shadow model on the same table. Defining the
# associations on AiCredential alone would leave the one surface that actually
# records this data unable to see it — the exact lesson of the P0 destroy-guard
# gap.
module AiCredentialContractTerms
  extend ActiveSupport::Concern

  included do
    # restrict_with_error, not destroy: the assessment history IS the evidence
    # for a claim the operator made to their own customers. Deleting a
    # credential must not silently take it along.
    has_many :documents, class_name: 'AiCredentialDocument',
                         foreign_key: :ai_credential_id,
                         dependent: :restrict_with_error, inverse_of: :ai_credential
    has_many :contracts, class_name: 'AiCredentialContract',
                         foreign_key: :ai_credential_id,
                         dependent: :restrict_with_error, inverse_of: :ai_credential
  end

  # The assessed version in force on `date`, or nil when nobody recorded one.
  # nil is a real state and stays distinguishable from "recorded, nothing
  # promised" — both read as "not assured" to the customer, but only one of them
  # is an open task for the operator.
  #
  # Filters in memory when the association is loaded: the customer catalogue
  # preloads contracts, and re-querying here would throw that preload away.
  def contract_on(date = Date.current)
    if contracts.loaded?
      contracts.select { |contract| contract.effective_on?(date) }.max_by(&:starts_on)
    else
      contracts.effective_on(date).order(starts_on: :desc).first
    end
  end

  def training_usage_on(date = Date.current)
    contract_on(date)&.training_usage || AiCredentialContract::TRAINING_UNSPECIFIED
  end

  def retention_policy_on(date = Date.current)
    contract_on(date)&.retention_policy || AiCredentialContract::RETENTION_UNSPECIFIED
  end

  def subprocessors_disclosure_on(date = Date.current)
    contract_on(date)&.subprocessors_disclosure || AiCredentialContract::SUBPROCESSORS_UNSPECIFIED
  end
end
