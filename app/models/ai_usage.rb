# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_usages
#
#  id               :uuid             not null, primary key
#  action           :string
#  cost_cents       :decimal(12, 6)   default(0.0)
#  credits_used     :integer          default(0), not null
#  metadata         :json
#  model_used       :string
#  provider         :string           not null
#  subject_type     :string
#  tokens_used      :integer          default(0)
#  used_at          :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  ai_credential_id :uuid
#  organisation_id  :uuid             not null
#  subject_id       :uuid
#  user_id          :uuid
#
# Indexes
#
#  index_ai_usages_on_ai_credential_id             (ai_credential_id)
#  index_ai_usages_on_organisation_id              (organisation_id)
#  index_ai_usages_on_organisation_id_and_used_at  (organisation_id,used_at)
#  index_ai_usages_on_provider_and_used_at         (provider,used_at)
#  index_ai_usages_on_subject_type_and_subject_id  (subject_type,subject_id)
#  index_ai_usages_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_credential_id => ai_credentials.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#

class AiUsage < ApplicationRecord
  # ================================
  # AI USAGE TRACKING & COST ESTIMATION
  # ================================
  # This model tracks all AI API usage across the application and provides
  # cost estimation and analytics capabilities.
  #
  # Key Features:
  # - Usage tracking via the single seam Lalabase::Llm::UsageTracking (S2)
  # - Token usage and cost estimation per API call
  # - Links usage to specific organisations and credentials
  # - Provider-specific cost calculation
  # - Analytics and reporting capabilities
  # - Metadata storage for additional context
  #
  # Usage Tracking Flow:
  # 1. A caller (ChatResponseJob or a migrated service) resolves a provider via
  #    Lalabase::Llm::Factory.for_feature(:its_key, org) and makes the call (R6).
  # 2. Lalabase::Llm::UsageTracking.record computes cost (CostCalculator) + attribution.
  # 3. After each API call, usage is recorded with:
  #    - Token counts (input/output tokens)
  #    - Estimated costs based on provider pricing
  #    - Model used and timestamp
  #    - Link to AiCredential if system credentials were used
  #
  # Cost Estimation:
  # - OpenAI: Based on model pricing (GPT-4, GPT-3.5, etc.)
  # - Other providers: Placeholder logic ready for implementation
  # - Costs stored in cents for precision
  # ================================

  # Associations
  belongs_to :organisation
  belongs_to :ai_credential, optional: true
  # S3: who triggered the call (nil for system/background jobs) and what it acted
  # on (polymorphic, nil for context-less actions like a chat message or search).
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  # Validations
  validates :provider, presence: true
  validates :tokens_used, numericality: { greater_than_or_equal_to: 0 }
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :credits_used, numericality: { greater_than_or_equal_to: 0 }
  validates :used_at, presence: true
  # action is validated against the registry with allow_nil (nullable-first
  # rollout, test 32): an old-shape row without an action stays valid, but a
  # NON-nil unknown value is rejected (test 14). New writers always set a valid one.
  validates :action, inclusion: { in: Lalabase::Llm::ActionRegistry.keys }, allow_nil: true

  # Scopes
  scope :recent, ->(days = 30) { where('used_at >= ?', days.days.ago) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :for_organisation, ->(org_id) { where(organisation_id: org_id) }
  # Rows that COUNT against an org's monthly quota: usage billed on a system
  # credential flagged included_in_quota. The inner join drops BYOK rows (nil
  # credential) automatically — BYOK usage is logged (transparency) but never
  # metered against the budget (plan §4.3, tests 6/8).
  scope :quota_counted, -> { joins(:ai_credential).where(ai_credentials: { included_in_quota: true }) }
  scope :in_month, ->(time = Time.current) { where(used_at: time.beginning_of_month..time.end_of_month) }

  # Callbacks
  before_validation :set_used_at, if: -> { used_at.blank? }

  class << self
    # Main method to track AI usage - called via Lalabase::Llm::UsageTracking
    #
    # @param organisation [Organisation] The organisation using the AI service
    # @param provider [String] AI provider name (openai, anthropic, etc.)
    # @param tokens_used [Integer] Number of tokens consumed
    # @param options [Hash] Additional options
    # @option options [AiCredential] :ai_credential The credential used (if system credential)
    # @option options [String] :model The AI model used (gpt-4, claude-3, etc.)
    # @option options [Integer] :cost_cents Estimated cost in cents
    # @option options [Hash] :metadata Additional metadata about the request
    #
    # @return [AiUsage] Created usage record
    #
    # Example:
    #   AiUsage.track_usage(
    #     organisation,
    #     'openai',
    #     1500,
    #     model: 'gpt-4',
    #     cost_cents: 45,
    #     ai_credential: system_credential,
    #     metadata: { endpoint: 'completions', user_id: '123' }
    #   )
    def track_usage(organisation, provider, tokens_used, options = {})
      create!(
        organisation: organisation,
        ai_credential: options[:ai_credential],
        user: options[:user],
        subject: options[:subject],
        provider: provider,
        action: options[:action],
        credits_used: options[:credits_used] || 0,
        model_used: options[:model],
        tokens_used: tokens_used,
        # default 0 (matches the column default) so an old caller that omits cost
        # doesn't trip the numericality validation with a nil.
        cost_cents: options[:cost_cents] || 0,
        used_at: Time.current,
        metadata: options[:metadata] || {}
      )
    end

    # Calculate total cost across all usage records
    #
    # @param days [Integer] Number of days to look back (default: 30)
    # @return [Float] Total cost in euros/dollars
    def total_cost(days = 30)
      recent(days).sum(:cost_cents) / 100.0
    end

    # Calculate total tokens used across all usage records
    #
    # @param days [Integer] Number of days to look back (default: 30)
    # @return [Integer] Total tokens consumed
    def total_tokens(days = 30)
      recent(days).sum(:tokens_used)
    end

    # Get usage statistics grouped by provider and model
    #
    # @param days [Integer] Number of days to look back (default: 30)
    # @return [Hash] Nested hash with provider -> model -> token_count
    def stats_by_provider(days = 30)
      recent(days)
        .group(:provider)
        .group(:model_used)
        .sum(:tokens_used)
    end

    def stats_by_organisation(days = 30)
      recent(days)
        .joins(:organisation)
        .group('organisations.name')
        .sum(:tokens_used)
    end
  end

  # Get cost in euros/dollars as a decimal
  #
  # @return [Float] Cost as decimal value (e.g., 1.23 for 123 cents)
  def cost_in_euros
    cost_cents / 100.0
  end

  # Get formatted cost string for display
  #
  # @return [String] Formatted cost string (e.g., "€1.23")
  def cost_formatted
    "€#{format('%.2f', cost_in_euros)}"
  end

  private

  def set_used_at
    self.used_at = Time.current
  end
end
