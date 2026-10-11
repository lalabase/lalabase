# frozen_string_literal: true

# =============================================================================
# Admin::AiUsage Model
# =============================================================================
# Special version of the AiUsage model for admin-backend operations.
# Uses the same table as the regular AiUsage model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular AiUsage model must be used.
# =============================================================================

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
module Admin
  class AiUsage < ApplicationRecord
    # Uses the same table as the regular AiUsage model
    self.table_name = 'ai_usages'

    # Route configuration for the admin namespace
    def self.model_name
      ActiveModel::Name.new(self, nil, 'AiUsage')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Associations (without tenant restrictions)
    belongs_to :organisation, class_name: 'Admin::Organisation'
    belongs_to :ai_credential, class_name: 'Admin::AiCredential', optional: true

    # Scopes for admin filtering and statistics
    scope :recent, ->(days = 30) { where('used_at >= ?', days.days.ago) }
    scope :by_provider, ->(provider) { where(provider: provider) }
    scope :ordered_by_date, -> { order(used_at: :desc) }
    scope :ordered_by_usage, -> { order(tokens_used: :desc) }
    scope :ordered_by_cost, -> { order(cost_cents: :desc) }

    # Admin-specific helper methods
    def organisation_name
      organisation&.name
    end

    def ai_credential_name
      ai_credential&.name || 'System-Credentials'
    end

    def provider_display
      provider&.capitalize || 'Unbekannt'
    end

    def cost_in_euros
      cost_cents / 100.0
    end

    def usage_date
      used_at&.strftime('%d.%m.%Y %H:%M') || '-'
    end

    def model_display
      model_used.presence || 'Unbekanntes Model'
    end

    # Statistics helper methods for the admin dashboard
    def self.total_tokens_for_period(days = 30)
      recent(days).sum(:tokens_used)
    end

    def self.total_cost_for_period(days = 30)
      recent(days).sum(:cost_cents)
    end

    def self.average_tokens_per_request(days = 30)
      scope = recent(days)
      usage_count = scope.count
      return 0 if usage_count == 0

      scope.sum(:tokens_used) / usage_count
    end

    def self.usage_by_provider(days = 30)
      recent(days)
        .group(:provider)
        .sum(:tokens_used)
    end

    def self.cost_by_provider(days = 30)
      recent(days)
        .group(:provider)
        .sum(:cost_cents)
    end

    def self.usage_by_organisation(days = 30)
      recent(days)
        .joins(:organisation)
        .group('organisations.name')
        .sum(:tokens_used)
    end

    def self.top_consuming_organisations(limit = 10, days = 30)
      recent(days)
        .joins(:organisation)
        .group('organisations.name')
        .order('sum_tokens_used DESC')
        .limit(limit)
        .sum(:tokens_used)
        .to_a
    end

    # Formatting helper methods
    def tokens_formatted
      tokens_used.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def cost_formatted
      "€ #{format('%.2f', cost_in_euros)}"
    end

    # CSS classes for provider badges
    def provider_css_class
      case provider&.downcase
      when ::AiCredential::PROVIDER_OPENAI
        'bg-green-100 text-green-800'
      # 'claude' is NOT part of the provider vocabulary — a legacy value that only
      # ever reached ai_usages rows, kept so old rows keep their badge colour.
      when 'claude', ::AiCredential::PROVIDER_ANTHROPIC
        'bg-blue-100 text-blue-800'
      when ::AiCredential::PROVIDER_GOOGLE
        'bg-yellow-100 text-yellow-800'
      else
        'bg-gray-100 text-gray-800'
      end
    end

    # Summary for admin display
    def usage_summary
      {
        organisation: organisation_name,
        provider: provider_display,
        model: model_display,
        tokens: tokens_used,
        cost_cents: cost_cents,
        cost_euros: cost_in_euros,
        date: usage_date,
        credential: ai_credential_name
      }
    end
  end
end
