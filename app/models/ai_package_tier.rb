# frozen_string_literal: true

# One rung of a package's performance ladder (KI-Pakete, doc/ki_pakete_plan.md
# §6, E2/E3): exactly two keys today — 'fast' ("Schnell & günstig") doubles as
# the utility tier for helper tasks (§2.1), 'thorough' ("Gründlich") is the
# deliberate-quality choice. Key and label are a PRODUCT decision (E2), not
# per-package operator freedom: the admin form renders them read-only and
# prefills from DEFAULT_LABELS (§7b.1 option C).
#
# chat_model optionally overrides chat_credential.default_model — that
# precedence is §6.1 Detailkonflikt 1 and gets wired in P2, not here.
# == Schema Information
#
# Table name: ai_package_tiers
#
#  id                 :uuid             not null, primary key
#  chat_model         :string
#  key                :string           not null
#  label              :string           not null
#  position           :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_package_id      :uuid             not null
#  chat_credential_id :uuid
#
# Indexes
#
#  idx_ai_package_tiers_unique_key_per_package   (ai_package_id,key) UNIQUE
#  index_ai_package_tiers_on_chat_credential_id  (chat_credential_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (chat_credential_id => ai_credentials.id)
#
class AiPackageTier < ApplicationRecord
  KEYS = %w[fast thorough].freeze
  # The rung an org runs on when it has not said otherwise — and the rung helper
  # tasks always take (§2.1, the utility tier). Named rather than read off
  # KEYS.first: "the cheapest one" is a product decision, not a list position.
  DEFAULT_KEY = 'fast'
  # Operator-facing data values (German product copy, E2) — stored per row so a
  # future rename is data maintenance, not a deploy.
  DEFAULT_LABELS = {
    'fast' => 'Schnell & günstig',
    'thorough' => 'Gründlich'
  }.freeze

  belongs_to :ai_package, inverse_of: :tiers
  belongs_to :chat_credential, class_name: 'AiCredential', optional: true

  # Same reason as AiPackage#normalise_blank_position: NOT NULL with a default
  # is no protection against an explicitly submitted "".
  before_validation :normalise_blank_position

  validates :key, inclusion: { in: KEYS }
  # Mirrors idx_ai_package_tiers_unique_key_per_package for rungs that already
  # live in the DB. In-memory siblings of one package never see each other here
  # (the query finds nothing yet) — that half is caught by
  # AiPackage#tier_keys_must_be_unique, because only the parent holds both.
  validates :key, uniqueness: { scope: :ai_package_id }
  validates :label, presence: true
  # On the association, not on chat_credential_id — see AiPackage.
  validates :chat_credential, presence: true

  # Same shape as the package's embedding-credential check: the select already
  # offers only these, the validation catches manipulation and the race where a
  # credential is disabled after the form was rendered (§7b.1). No provider
  # filter here — every implemented provider can chat, and coupling chat to the
  # embedding provider is exactly the mistake §9 Falle 2 warns against.
  validate :chat_credential_must_be_chat_capable
  validate :chat_model_must_exist_in_vertex_region, if: :vertex_check_due?

  # Which model this rung actually talks to: the per-tier override wins over the
  # credential's default (§7b.1, the operator-facing half of §6.1's precedence
  # question — the org-level `preferred_chat_model` leg is P2's business).
  def effective_chat_model
    chat_model.presence || chat_credential&.default_model
  end

  private

  def normalise_blank_position
    self.position = 0 if position.blank?
  end

  def chat_credential_must_be_chat_capable
    return if chat_credential.nil?

    errors.add(:chat_credential, :disabled) unless chat_credential.enabled?
    return if AiCredentialPricing::CHAT_PURPOSES.include?(chat_credential.purpose)

    errors.add(:chat_credential, :wrong_purpose)
  end

  def vertex_check_due?
    chat_credential&.provider == AiPackage::FOREIGN_PROVIDER_IN_EU && effective_chat_model.present? &&
      (new_record? || will_save_change_to_chat_credential_id? || will_save_change_to_chat_model?)
  end

  def chat_model_must_exist_in_vertex_region
    model = effective_chat_model
    region = AiPackage.unavailable_vertex_region(credential: chat_credential, model: model)
    return if region.nil?

    errors.add(:chat_model, :vertex_model_unavailable, model: model, region: region)
  end
end
