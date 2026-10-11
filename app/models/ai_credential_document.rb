# frozen_string_literal: true

# One VERSION of one contractual document of a provider
# (doc/ki_vertragsdaten_plan.md § 4). Google alone has three such papers, and
# none of them covers everything — which is why the assessment lives in
# AiCredentialContract and merely points here.
#
# No EffectiveDating: two versions of the same paper may legitimately overlap
# (the new one is published while the old still governs existing agreements).
# `valid_from` is a property of the paper, not an exclusive validity window.
class AiCredentialDocument < ApplicationRecord
  # 25 MB: large enough for the terms PDFs providers actually publish, small
  # enough that a mis-picked file fails at the boundary instead of in storage.
  MAX_FILE_SIZE = 25.megabytes
  ALLOWED_CONTENT_TYPE = 'application/pdf'
  # The document list renders `url` through `link_to`, which does NOT filter the
  # scheme — a stored `javascript:` URL becomes a click payload on the admin page,
  # in the admin's own origin and session. Guarding here rather than in a
  # controller because the operator types this field on two write paths (record
  # and correct), and a rule enforced per path is a rule enforced once too often.
  ALLOWED_URL_SCHEMES = %r{\Ahttps?://}i

  belongs_to :ai_credential
  has_many :contract_documents, class_name: 'AiCredentialContractDocument',
                                dependent: :restrict_with_error, inverse_of: :ai_credential_document
  has_many :contracts, through: :contract_documents, source: :ai_credential_contract

  has_one_attached :file

  # Normalised BEFORE validation, so the uniqueness index sees the same value the
  # history grouping does. Without it "SST" and "sst" split one paper's history
  # into two, and the operator sees two half-histories without anything failing.
  before_validation :normalise_document_key

  validates :document_key, presence: true
  validates :title, presence: true
  validates :valid_from, presence: true
  validates :document_key, uniqueness: { scope: %i[ai_credential_id valid_from] }
  validates :url, format: { with: ALLOWED_URL_SCHEMES, message: :not_http_url }, allow_blank: true
  validate :file_must_be_a_reasonable_pdf

  scope :for_key, ->(document_key) { where(document_key: document_key) }
  scope :newest_first, -> { order(valid_from: :desc, created_at: :desc) }

  # The version of THIS paper in force on `date` — the newest one that has
  # started. Not an EffectiveDating question: versions may overlap, so "current"
  # means "most recent", not "the one whose window contains the date".
  def self.current_version(scope, on: Date.current)
    scope.where(valid_from: ..on).newest_first.first
  end

  # Evidence is only evidence if it can be reached: either the paper is attached
  # or it is linked. A row with neither is a note, not a document.
  def evidence?
    file.attached? || url.present?
  end

  private

  def normalise_document_key
    self.document_key = document_key.to_s.strip.downcase.presence
  end

  def file_must_be_a_reasonable_pdf
    return unless file.attached?

    errors.add(:file, :not_a_pdf) unless file.content_type == ALLOWED_CONTENT_TYPE
    errors.add(:file, :too_large, limit: MAX_FILE_SIZE / 1.megabyte) if file.byte_size > MAX_FILE_SIZE
  end
end
