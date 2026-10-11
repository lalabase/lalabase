# frozen_string_literal: true

# The ASSESSED version of what a provider promises about customer content
# (doc/ki_vertragsdaten_plan.md § 4/D2). Separate from the documents, because
# evidence and conclusion age independently.
#
# Never derived from the document text (D2): a machine reading would put an
# assurance on the customer card that nobody verified, and in a dispute the
# operator answers for the statement, not the model.
#
# Shares EffectiveDating with PriceList and AccountDiscount: ends_on is
# INCLUSIVE, and two assessed versions of one credential may not overlap —
# "what did we state on date X" must have exactly one answer.
class AiCredentialContract < ApplicationRecord
  include EffectiveDating

  effective_dating_scope :ai_credential_id

  belongs_to :ai_credential
  has_many :contract_documents, class_name: 'AiCredentialContractDocument',
                                dependent: :destroy, inverse_of: :ai_credential_contract
  has_many :documents, through: :contract_documents, source: :ai_credential_document

  # ── Training: does the provider train on customer content? ───────────────────
  TRAINING_EXCLUDED = 'excluded'
  TRAINING_USED = 'used'
  TRAINING_UNSPECIFIED = 'unspecified'
  TRAINING_USAGES = [TRAINING_EXCLUDED, TRAINING_USED, TRAINING_UNSPECIFIED].freeze

  # Worst first: a package is only as good as its weakest credential, so the
  # FIRST match in this order wins the aggregation.
  TRAINING_SEVERITY = [TRAINING_USED, TRAINING_UNSPECIFIED, TRAINING_EXCLUDED].freeze

  # ── Retention: how long are inputs and outputs kept? ─────────────────────────
  # A separate axis, because "no training" says nothing about storage: OpenAI
  # excludes training by default AND keeps API traffic for up to 30 days.
  RETENTION_NONE = 'none'
  RETENTION_LIMITED = 'limited'
  RETENTION_UNLIMITED = 'unlimited'
  RETENTION_UNSPECIFIED = 'unspecified'
  RETENTION_POLICIES = [RETENTION_NONE, RETENTION_LIMITED, RETENTION_UNLIMITED,
                        RETENTION_UNSPECIFIED].freeze
  RETENTION_SEVERITY = [RETENTION_UNLIMITED, RETENTION_UNSPECIFIED, RETENTION_LIMITED,
                        RETENTION_NONE].freeze

  # ── Sub-processors: does the provider disclose who else touches the data? ────
  SUBPROCESSORS_DISCLOSED = 'disclosed'
  SUBPROCESSORS_UNDISCLOSED = 'undisclosed'
  SUBPROCESSORS_UNSPECIFIED = 'unspecified'
  SUBPROCESSORS_DISCLOSURES = [SUBPROCESSORS_DISCLOSED, SUBPROCESSORS_UNDISCLOSED,
                               SUBPROCESSORS_UNSPECIFIED].freeze
  # Same shape as the other two axes: the bad FACT outranks the missing
  # assessment, which outranks the good fact. "The provider names nobody" is a
  # worse answer than "we have not looked yet", because one of them is settled.
  SUBPROCESSORS_SEVERITY = [SUBPROCESSORS_UNDISCLOSED, SUBPROCESSORS_UNSPECIFIED,
                            SUBPROCESSORS_DISCLOSED].freeze

  validates :training_usage, inclusion: { in: TRAINING_USAGES }
  validates :retention_policy, inclusion: { in: RETENTION_POLICIES }
  validates :subprocessors_disclosure, inclusion: { in: SUBPROCESSORS_DISCLOSURES }
  validates :retention_days, numericality: { only_integer: true, greater_than: 0 },
                             if: -> { retention_policy == RETENTION_LIMITED }
  validate :retention_days_only_when_limited

  def training_excluded?
    training_usage == TRAINING_EXCLUDED
  end

  private

  # A day count next to "no retention" is a contradiction, and a missing one
  # under 'limited' makes the statement useless ("we keep it — for how long?").
  def retention_days_only_when_limited
    return if retention_policy == RETENTION_LIMITED || retention_days.blank?

    errors.add(:retention_days, :only_with_limited_retention)
  end
end
