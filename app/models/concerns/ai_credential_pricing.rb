# frozen_string_literal: true

# Shared pricing rules for the two classes mapping to the ai_credentials table:
# AiCredential (runtime) and Admin::AiCredential (the admin BACKEND, which is the
# actual create/edit surface). The guard MUST live on both, otherwise it is toothless
# on the path where credentials are really written and a metered credential could be
# saved without prices — CostCalculator would then silently meter it at 0 (S3
# under-billing). `purpose` drives which price fields a quota credential must carry.
module AiCredentialPricing
  extend ActiveSupport::Concern

  PURPOSES = %w[chat embedding both].freeze
  CHAT_PURPOSES = %w[chat both].freeze
  EMBEDDING_PURPOSES = %w[embedding both].freeze

  included do
    validates :purpose, inclusion: { in: PURPOSES }
    validate :quota_credentials_have_prices
  end

  private

  # A metered (included_in_quota) credential must carry the prices we bill it at.
  # Purpose-aware: only the fields the credential actually uses are required.
  def quota_credentials_have_prices
    return unless included_in_quota?

    if CHAT_PURPOSES.include?(purpose)
      require_price(:input_cost_per_1m_cents)
      require_price(:output_cost_per_1m_cents)
    end
    require_price(:embedding_cost_per_1m_cents) if EMBEDDING_PURPOSES.include?(purpose)
  end

  def require_price(attribute)
    errors.add(attribute, :required_for_quota) unless public_send(attribute).to_i.positive?
  end
end
