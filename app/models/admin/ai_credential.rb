# frozen_string_literal: true

# =============================================================================
# Admin::AiCredential Model
# =============================================================================
# Special version of the AiCredential model for admin-backend operations.
# Uses the same table as the regular AiCredential model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular AiCredential model must be used.
# =============================================================================

# == Schema Information
#
# Table name: ai_credentials
#
#  id                          :uuid             not null, primary key
#  access_token                :text             not null
#  active                      :boolean          default(FALSE)
#  additional_config           :json
#  api_base                    :string
#  company_domicile            :string
#  default_model               :string
#  description                 :text
#  display_name                :string
#  embedding_cost_per_1m_cents :integer
#  enabled                     :boolean          default(TRUE)
#  included_in_quota           :boolean          default(FALSE), not null
#  input_cost_per_1m_cents     :integer
#  name                        :string           not null
#  output_cost_per_1m_cents    :integer
#  provider                    :string           default("openai"), not null
#  purpose                     :string           default("both"), not null
#  region                      :string
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  organization_id             :string
#
# Indexes
#
#  index_ai_credentials_on_active               (active)
#  index_ai_credentials_on_enabled              (enabled)
#  index_ai_credentials_on_provider             (provider)
#  index_ai_credentials_on_provider_and_active  (provider,active) UNIQUE WHERE (active = true)
#
module Admin
  class AiCredential < ApplicationRecord
    # Contract documents + assessed versions: the same shared concern as in the
    # runtime model. The admin area is the surface that records them.
    include AiCredentialContractTerms
    # Admin edits + admin activation must drop the same active_for_provider cache
    # the runtime AiCredential reads — otherwise a price/config change is ignored
    # for up to 5 minutes. Shared with the runtime model so they cannot drift.
    include AiCredentialCacheable
    # Enforce the quota price guard HERE too — this is the surface where credentials
    # are actually created/edited, so the guard would be toothless on the runtime
    # model alone.
    include AiCredentialPricing
    # S1 honest facade: same reasoning — this model previously validated the
    # provider not at all (only presence), so ANY string could be saved through
    # the admin backend. Shared concern = one rule set on both write paths.
    include AiCredentialProviderRules
    # #test_connection, shared for the same reason. The probe is identical on
    # both write paths — both models declare `encrypts :access_token`, so the
    # concern's plain attribute read decrypts here too (no override needed).
    include AiCredentialConnectivity
    # The guard against deleting a provider's last active credential. It lived on
    # the runtime model, which no destroy ever touches: THIS class is what
    # Admin::AiCredentialsController#destroy loads, so until the include the
    # protection did nothing at all.
    include AiCredentialDestroyProtection

    PROVIDER_CSS_CLASSES = {
      ::AiCredential::PROVIDER_OPENAI => 'bg-green-100 text-green-800',
      ::AiCredential::PROVIDER_ANTHROPIC => 'bg-blue-100 text-blue-800',
      # 'claude' is NOT part of the provider vocabulary — a legacy value that
      # only ever reached ai_usages rows, kept so old badges keep their colour.
      'claude' => 'bg-blue-100 text-blue-800',
      ::AiCredential::PROVIDER_GOOGLE => 'bg-yellow-100 text-yellow-800'
    }.freeze

    DEFAULT_PROVIDER_CSS_CLASS = 'bg-gray-100 text-gray-800'

    # Fixed-width token mask for the detail/edit surfaces. A per-character mask
    # turns a service-account JSON (thousands of chars) into a card-breaking wall
    # of asterisks; a constant five is all the "it's hidden" signal a single
    # credential page needs (the list uses #key_fingerprint for identifiability).
    # The '*' is load-bearing: AiCredentialsController#update drops any submitted
    # access_token containing '*' (masked = unchanged), so this round-trips safely.
    MASKED_TOKEN = '*****'

    self.table_name = 'ai_credentials'

    def self.model_name
      ActiveModel::Name.new(self, nil, 'AiCredential')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Encrypt the access_token at rest. This admin model is the REAL write path
    # for AI credentials (create/edit run through Admin::AiCredentialsController),
    # so WITHOUT this the service-account JSON / API keys were persisted as
    # CLEARTEXT — while the runtime AiCredential encrypted the very same column.
    # Same scheme as the runtime model (ai_credential.rb) so the two write paths
    # cannot drift. Legacy cleartext rows keep reading via support_unencrypted_data
    # until `encryption:reencrypt_tokens` (TokenReencryptable sweep) rewrites them.
    encrypts :access_token, deterministic: false

    # Associations — nullify instead of destroy, so that audit data (usages) is preserved
    has_many :ai_usages, class_name: 'Admin::AiUsage', dependent: :nullify

    # Validations. This block used to claim "same data integrity as the regular
    # model" — it was not. Both classes write the SAME table, so every rule the
    # runtime model enforces and this one does not is a row the admin path can
    # create and the runtime path then rejects.
    #
    # default_model closed here because that gap was REACHABLE (review of #391):
    # an active openai_compatible credential without a model passes the org gate
    # (system_ai_credential_usable? only asked `enabled?`), and the call then dies
    # at OpenAiCompatibleProvider#default_chat_model, which has no fallback. The
    # org-side half of that gate is fixed in the same PR.
    #
    # What is STILL missing here, measured against the runtime model on 2026-08-02
    # (`AiCredential.validators` / `_validate_callbacks` diffed, not eyeballed):
    #   * name uniqueness
    #   * active uniqueness per provider
    #   * validate_access_token_format
    # Left open deliberately: each of these can reject rows that legitimately exist
    # today, so each needs its own data check before it is added — a blanket copy
    # would lock admins out of editing exactly the records they need to repair.
    #
    # NOT missing, although a glance at this block suggests it: the provider
    # whitelist. The runtime model spells it as `inclusion: PROVIDERS`, while both
    # classes share the STRICTER provider_must_be_implemented from
    # AiCredentialProviderRules (implemented ⊂ PROVIDERS).
    validates :name, presence: true
    validates :provider, presence: true
    validates :access_token, presence: true
    validates :default_model, presence: true

    # Scopes for admin filtering
    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :by_provider, ->(provider) { where(provider: provider) }
    scope :ordered_by_name, -> { order(:name) }
    scope :ordered_by_provider, -> { order(:provider, :name) }

    def self.providers
      distinct.pluck(:provider).compact.sort
    end

    def self.activate!(credential_id)
      transaction do
        credential = find(credential_id)
        where(provider: credential.provider).update_all(active: false)
        credential.update!(active: true)
      end
    end

    # Backfill for the `encrypts :access_token` addition above (rows written
    # before encryption existed sit as CLEARTEXT in the column) and key
    # ROTATION: every processed row ends up under the CURRENT primary key.
    # Semantics live in TokenReencryptable (was hand-rolled here; unified when
    # the sweep had to cover all six encrypted columns). This model registers
    # for the ai_credentials TABLE — deliberately the admin shadow, not the
    # runtime AiCredential, because the legacy entry point below and its rake
    # wrapper (ai_credentials:reencrypt_access_tokens) already live here.
    # Tenant reach is NOT the reason: neither class is tenant-scoped, and the
    # concern wraps every sweep in ActsAsTenant.without_tenant anyway.
    # The old entry-point name stays for the existing rake task and ops docs.
    include TokenReencryptable
    reencrypts_tokens :access_token

    def self.reencrypt_access_tokens!
      reencrypt_tokens!
    end

    def status_text
      if active?
        enabled? ? I18n.t('models.admin_ai_credential.status.active_enabled') : I18n.t('models.admin_ai_credential.status.active_disabled')
      else
        I18n.t('models.admin_ai_credential.status.inactive')
      end
    end

    def organization_display
      organization_id.presence || I18n.t('models.admin_ai_credential.display.no_organization_id')
    end

    def model_display
      default_model.presence || I18n.t('models.admin_ai_credential.display.no_default_model')
    end

    def has_access_token?
      access_token.present?
    end

    def masked_access_token
      return I18n.t('models.admin_ai_credential.display.no_token') if access_token.blank?

      MASKED_TOKEN
    end

    alias masked_token masked_access_token

    # Short, scannable key identifier for list views: type prefix + last 4 chars
    # (e.g. "sk-…3hLx"). Reveals neither the key length nor a wall of asterisks,
    # and unlike the fixed MASKED_TOKEN it stays distinguishable between keys.
    def key_fingerprint
      return I18n.t('models.admin_ai_credential.display.no_token') if access_token.blank?
      return "…#{access_token.last(4)}" if access_token.length <= 8

      "#{access_token.first(3)}…#{access_token.last(4)}"
    end

    # Statistics methods for the admin dashboard
    def total_usage_tokens
      ai_usages.sum(:tokens_used)
    end

    def total_usage_cost_cents
      ai_usages.sum(:cost_cents)
    end

    def recent_usage_tokens(days = 30)
      ai_usages.recent(days).sum(:tokens_used)
    end

    def recent_usage_cost_cents(days = 30)
      ai_usages.recent(days).sum(:cost_cents)
    end

    def usage_count
      ai_usages.count
    end

    def recent_usage_count(days = 30)
      ai_usages.recent(days).count
    end

    def status_css_class
      if active? && enabled?
        'bg-green-100 text-green-800'
      elsif active?
        'bg-yellow-100 text-yellow-800'
      else
        'bg-red-100 text-red-800'
      end
    end

    def provider_css_class
      PROVIDER_CSS_CLASSES.fetch(provider&.downcase, DEFAULT_PROVIDER_CSS_CLASS)
    end

    def additional_config_display
      return I18n.t('models.admin_ai_credential.display.no_extra_config') if additional_config.blank?

      additional_config.map { |key, value| "#{key.humanize}: #{value}" }.join(', ')
    end

    # Display names come from the ONE source on the runtime model (S1 facade
    # cleanup) — this class used to carry its own diverging map, including a
    # phantom 'claude' key that no provider column value ever had.
    def provider_display_name
      ::AiCredential.provider_display_names[provider&.downcase] || provider&.capitalize
    end

    def usage_stats(days = 30)
      count = recent_usage_count(days)
      tokens = recent_usage_tokens(days)

      {
        total_requests: count,
        total_tokens: tokens,
        total_cost_cents: recent_usage_cost_cents(days),
        average_tokens_per_request: count > 0 ? tokens / count : 0
      }
    end

    # #test_connection lives in AiCredentialConnectivity. The google probe that
    # used to sit here is unchanged in substance — it now runs as
    # GoogleVertexProvider#connectivity_check, which mints the same OAuth token
    # and thereby validates the whole service-account JSON. The other providers
    # gained a real probe instead of their `access_token.present?` stub.

    def credential_summary
      {
        name: name,
        provider: provider_display_name,
        status: status_text,
        organization_id: organization_display,
        default_model: model_display,
        total_usage_tokens: total_usage_tokens,
        total_usage_cost_cents: total_usage_cost_cents,
        recent_usage_tokens: recent_usage_tokens,
        recent_usage_cost_cents: recent_usage_cost_cents,
        usage_count: usage_count,
        has_access_token: has_access_token?
      }
    end
  end
end
