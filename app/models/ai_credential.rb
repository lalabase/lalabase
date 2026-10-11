# frozen_string_literal: true

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

class AiCredential < ApplicationRecord
  include AiCredentialCacheable
  # PURPOSES + the purpose/price validations live in the shared concern so the admin
  # backend model (Admin::AiCredential) — the real editing surface — enforces them too.
  include AiCredentialPricing
  # S1 honest facade: provider must be implemented (Factory-buildable) on
  # create/change, purpose must match the provider's embedding capability, and
  # only implemented providers can be activated. Shared concern for the same
  # reason as AiCredentialPricing (admin model is the real write path).
  include AiCredentialProviderRules
  # #test_connection for BOTH models. Was per-model before, and each copy was
  # honest for exactly one provider (openai here, google in the admin model) —
  # everything else got a `access_token.present?` stub. Shared for the same
  # reason as the concerns above.
  include AiCredentialConnectivity
  # The before_destroy guard against deleting a provider's last active
  # credential. Shared because it was registered here ONLY while every destroy
  # in the app goes through the admin model — see the concern's header.
  include AiCredentialDestroyProtection
  # Contract documents + assessed versions. Shared concern, because the admin
  # area writes through Admin::AiCredential (see the concern's header).
  include AiCredentialContractTerms

  # The provider vocabulary. THE one definition of these routing keys — every
  # comparison, case branch and default argument in the app reads them from here
  # instead of repeating the literal (Organisation, the Factory registry, the
  # provider rules). A typo in a literal fails silently as "no match"; a typo in a
  # constant raises NameError.
  PROVIDER_OPENAI = 'openai'

  # COMPANY_DOMICILE* constants (E12) live in AiCredentialProviderRules — the
  # concern's included-block validation reads them at class-load time, and this
  # class is still mid-load when the include runs (same autoload-cycle reason
  # the concern documents for implemented_providers). Reachable here as
  # AiCredential::COMPANY_DOMICILES via the include, as before.
  PROVIDER_ANTHROPIC = 'anthropic'
  PROVIDER_GOOGLE = 'google'
  PROVIDER_OPENAI_COMPATIBLE = 'openai_compatible'

  # All provider values that may exist in the DB. Superset of
  # implemented_providers (currently identical — 'cohere' remains the removed
  # legacy value that keeps the distinction alive); selectability derives from
  # the Factory registry via AiCredentialProviderRules.
  PROVIDERS = [PROVIDER_OPENAI, PROVIDER_ANTHROPIC, PROVIDER_GOOGLE, PROVIDER_OPENAI_COMPATIBLE].freeze

  PROVIDER_DISPLAY_NAMES = {
    PROVIDER_OPENAI => 'OpenAI (GPT)',
    PROVIDER_ANTHROPIC => 'Anthropic (Claude)',
    PROVIDER_GOOGLE => 'Google (Gemini)',
    # OpenAI-compatible embedding/chat endpoint (Azure / LiteLLM / self-hosted).
    # The endpoint base URL is stored in additional_config['uri_base'].
    PROVIDER_OPENAI_COMPATIBLE => 'OpenAI-kompatibel (eigener Endpunkt)'
  }.freeze

  MASKED_TOKEN_PREFIXES = {
    PROVIDER_OPENAI => 'sk-',
    PROVIDER_ANTHROPIC => 'sk-ant-',
    # google carries a service-account JSON, not an AIza… API key — there is
    # no meaningful prefix to reveal, mask in full (like openai_compatible).
    PROVIDER_GOOGLE => '',
    PROVIDER_OPENAI_COMPATIBLE => ''
  }.freeze

  # Curated EU chat presets for the openai_compatible provider rail (S2). Pure
  # data, no behaviour: the admin "new" form offers them as an optional prefill
  # (admin_ai_credential_preset_controller.js); every field stays editable —
  # a preset is a starting aid, not a lock-in.
  #
  # Chat only, and no longer for a technical reason (E6): 1024-dim spaces are
  # storable and indexable since embedding v2 PR 5, so mistral-embed & co. are
  # usable — they simply have no PRESET yet. Azure OpenAI is deliberately absent
  # for a reason that still holds: its endpoint is deployment-specific, there is
  # no honest fixed URL.
  #
  # Endpoints verified against provider docs on 2026-08-04 — model names age
  # quickly, verify against provider docs again before prod.
  #
  # Model names are PINNED, never a '-latest' alias. An alias silently rolls
  # over to a new model version, and verifying it before prod does not help —
  # it changes AFTER the check. Three things would then be wrong at once with
  # nothing failing: the per-1M prices live on the credential, so a metered
  # credential bills the new model at the old model's price; the Art. 13 notice
  # names a model that no longer answers; and the package promises a model
  # class that changed under the customer.
  #
  # All three carry company_domicile 'eu' (E12): Mistral AI (FR), IONOS SE (DE)
  # and OVHcloud (FR) are EU companies, and the preset is the one place that
  # knows it — the provider value is 'openai_compatible' for all three, so
  # nothing about the credential itself could answer the question afterwards
  # (§3.4, why a provider-name list was rejected).
  EU_CHAT_PRESETS = {
    'mistral' => {
      display_name: 'Mistral (EU)',
      api_base: 'https://api.mistral.ai/v1',
      default_model: 'mistral-large-3',
      region: 'eu',
      company_domicile: COMPANY_DOMICILE_EU,
      purpose: 'chat'
    },
    'ionos' => {
      display_name: 'IONOS AI Model Hub (DE)',
      api_base: 'https://openai.inference.de-txl.ionos.com/v1',
      default_model: 'meta-llama/Llama-3.3-70B-Instruct',
      region: 'eu',
      company_domicile: COMPANY_DOMICILE_EU,
      purpose: 'chat'
    },
    'ovhcloud' => {
      display_name: 'OVHcloud AI Endpoints (EU)',
      api_base: 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1',
      default_model: 'mistral-small-3.2-24b-instruct',
      region: 'eu',
      company_domicile: COMPANY_DOMICILE_EU,
      purpose: 'chat'
    }
  }.freeze

  # Encrypt sensitive data
  encrypts :access_token, deterministic: false

  # Validations
  validates :name, presence: true, uniqueness: true
  validates :provider, presence: true, inclusion: {
    in: PROVIDERS,
    message: :supported_provider
  }
  validates :access_token, presence: true
  validates :default_model, presence: true
  # company_domicile validation lives in AiCredentialProviderRules — the shared
  # concern both write paths load. Validating it here alone would be toothless:
  # Admin::AiCredential is the surface the field is actually edited on (the
  # exact lesson of the P0 destroy-guard gap).

  # Only one credential per provider can be active
  validates :active, uniqueness: {
    scope: :provider,
    message: :one_active_per_provider
  }, if: :active?

  # Validate access token format based on provider
  validate :validate_access_token_format

  # Scopes
  scope :active, -> { where(active: true) }
  scope :enabled, -> { where(enabled: true) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  # Associations
  has_many :ai_usages, dependent: :nullify
  # Callbacks
  after_update :log_sensitive_changes
  # Cache invalidation (after_save + after_destroy, on EVERY write) lives in
  # AiCredentialCacheable, the last-active destroy guard in
  # AiCredentialDestroyProtection — both so the admin write path is covered too.

  class << self
    # Get the active credential for a specific provider with caching
    #
    # @param provider [String] Provider name (openai, anthropic, ...)
    # @return [AiCredential, nil] Active credential for provider or nil
    #
    # This method is cached for 5 minutes to improve performance as it's called
    # frequently during AI API requests.
    def active_for_provider(provider = PROVIDER_OPENAI)
      # Read through the SAME key AiCredentialCacheable deletes on write — sourced
      # from one place so the read key and the invalidation key can never drift.
      Rails.cache.fetch(AiCredentialCacheable.cache_key_for(provider), expires_in: 5.minutes) do
        active.for_provider(provider).first
      end
    end

    # Activate a specific credential and deactivate all others for the same provider
    #
    # @param id [String, Integer] ID of the credential to activate
    # @return [AiCredential] The activated credential
    #
    # This operation is atomic - either all credentials are properly updated or none are.
    # Cache is automatically cleared after activation.
    def activate!(id)
      transaction do
        credential = find(id)
        # Deactivate all others of the same provider
        where(provider: credential.provider).update_all(active: false)
        credential.update!(active: true)
        Rails.logger.info "AI Credential #{credential.name} (#{credential.provider}) activated"
      end
    end

    # .with_failover ("active credential, else first enabled of the provider") was
    # removed in KI-Pakete P0: it had specs but not a single production caller,
    # and its semantics — silently promoting an arbitrary enabled credential —
    # contradict credential-addressed packages (doc/ki_pakete_plan.md §4.1).

    def providers
      PROVIDERS
    end

    # Full display map (incl. announced-but-unimplemented providers like
    # 'google') — used to LABEL existing rows/settings. For select boxes use
    # provider_options_for_select, which filters to implemented providers.
    def provider_display_names
      PROVIDER_DISPLAY_NAMES
    end

    # Label/value pairs for the provider select boxes (admin forms + org
    # settings). Only providers the Factory can actually build are offered
    # (honest facade, S1); `current:` re-adds an existing row's legacy provider
    # so an edit form keeps its selection instead of silently jumping to the
    # first implemented option.
    def provider_options_for_select(current: nil)
      selectable = implemented_providers
      selectable |= [current] if current.present?
      selectable.map { |provider| [PROVIDER_DISPLAY_NAMES.fetch(provider, provider.capitalize), provider] }
    end
  end

  # Generate a masked version of the access token for safe display
  #
  # @return [String, nil] Masked token showing provider prefix and last few characters
  #
  # Examples:
  # - OpenAI: "sk-***************************abc123"
  # - Anthropic: "sk-ant-*********************xyz789"
  def masked_token
    return nil unless access_token.present?

    prefix = MASKED_TOKEN_PREFIXES.fetch(provider, '')
    suffix_length = [access_token.length / 4, 8].min
    mask_length = [access_token.length - prefix.length - suffix_length, 0].max

    prefix + '*' * mask_length + access_token.last(suffix_length)
  end

  # #client_instance was removed together with the per-model #test_connection
  # it backed: an UNGATED OpenAI::Client that bypassed both the BYOK routing
  # and the ai_enabled opt-in gate. Every client now comes from
  # Lalabase::Llm::Factory, so app/models/ai_credential.rb could also leave the
  # allowlist in spec/services/lalabase/llm/direct_client_guard_spec.rb.

  def provider_display_name
    self.class.provider_display_names[provider] || provider.capitalize
  end

  # #test_connection now lives in AiCredentialConnectivity — it probes EVERY
  # implemented provider via Provider#connectivity_check instead of making a
  # real call for openai only and stubbing the rest with `access_token.present?`.

  # Get total tokens used for this credential within the given time window
  #
  # @param days [Integer] Number of days to look back (default: 30)
  # @return [Integer] Total tokens used
  def usage_stats(days = 30)
    ai_usages
      .where('used_at >= ?', days.days.ago)
      .sum(:tokens_used)
  end

  private

  def validate_access_token_format
    return unless access_token.present?

    case provider
    when PROVIDER_ANTHROPIC
      errors.add(:access_token, :invalid_anthropic_key) unless access_token.match?(/\Ask-ant-[a-zA-Z0-9\-_]{95,}\z/)
    end
  end

  def log_sensitive_changes
    return unless saved_change_to_access_token? || saved_change_to_active?

    Rails.logger.warn "AI Credential #{id} (#{name}, #{provider}) sensitive data changed"
  end
end
