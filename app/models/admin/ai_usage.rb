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

    # Admin-specific helper methods
    def cost_in_euros
      cost_cents / 100.0
    end

    # Formatting helper methods
    def cost_formatted
      "€ #{format('%.2f', cost_in_euros)}"
    end
  end
end
