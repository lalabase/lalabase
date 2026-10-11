# frozen_string_literal: true

# Shared provider rules for the two classes mapping to the ai_credentials table:
# AiCredential (runtime) and Admin::AiCredential (the admin BACKEND, which is the
# actual create/edit surface — without the include there the rules would be
# toothless on the path where credentials are really written; precedent:
# AiCredentialPricing).
#
# S1 "honest facade": a credential must never promise what
# Lalabase::Llm::Factory cannot deliver. Three rules:
#   1. provider must be implemented — checked on create and on provider change,
#      so existing legacy rows (provider google/cohere) stay readable, editable
#      and deletable, they just cannot be (re)selected.
#   2. purpose may only include embeddings when the provider class declares
#      supports_embeddings? — checked on create and on provider/purpose change
#      (same legacy-row tolerance: an old anthropic/both row is not bricked,
#      but any attempt to SET such a combination is rejected).
#   3. active: true is reserved for implemented providers, so
#      active_for_provider can never route runtime traffic to an unbuildable
#      provider. Checked on activation (create or active flip), so legacy-active
#      rows keep accepting unrelated edits.
#   4. google credentials must carry a service-account JSON in access_token:
#      Vertex auth is service-account-only (an API key would silently use the
#      GLOBAL endpoint and void EU data residency — doc/ki_provider_dsgvo_plan.md
#      §3.2). Checked on token/provider change so a legacy google row (AIza… key
#      from the facade era) stays editable until its token is touched. Unlike
#      the anthropic key-format check (runtime model only, predates S1), this
#      lives here so the admin backend — the real write path — enforces it.
module AiCredentialProviderRules
  extend ActiveSupport::Concern

  # The two keys googleauth actually needs to mint a token; their presence is
  # the cheapest honest "this is a service-account JSON" check.
  GOOGLE_SERVICE_ACCOUNT_KEYS = %w[private_key client_email].freeze

  # E12 (plan §3.3): the two independent facts a package jurisdiction derives
  # from. The processing side lives in #region ('eu'/'us'); this is the COMPANY
  # seat. NULL = not recorded — eu_native claims stay fail-closed on it.
  # Defined IN the concern (not on AiCredential) because the included-block
  # validation below reads it while the including class is still mid-load —
  # both models reach it as <Model>::COMPANY_DOMICILES via the include.
  COMPANY_DOMICILES = %w[eu non_eu].freeze
  COMPANY_DOMICILE_EU = 'eu'
  COMPANY_DOMICILE_NON_EU = 'non_eu'

  included do
    validate :provider_must_be_implemented, if: :provider_selection_changing?
    validate :purpose_must_match_provider_capability, if: :purpose_selection_changing?
    validate :activation_requires_implemented_provider, if: :activating?
    validate :google_token_must_be_service_account_json, if: :google_token_selection_changing?
    # E12 (plan §3.3): the company-seat axis of the jurisdiction derivation.
    # allow_BLANK, not allow_nil — the admin select carries an empty option and
    # "" from a form must read as "not recorded", never as an invalid value;
    # readers ask .present? for exactly that reason. Lives HERE because
    # Admin::AiCredential is the surface the field is edited on — a runtime-only
    # rule would be toothless (the P0 destroy-guard lesson).
    validates :company_domicile, inclusion: {
      in: COMPANY_DOMICILES,
      message: :supported_domicile
    }, allow_blank: true
  end

  class_methods do
    # Selectable providers = exactly what the Factory can build. A lazy method,
    # NOT a constant: the model class body must never touch the service constant
    # (autoload circularity model <-> service).
    def implemented_providers
      Lalabase::Llm::Factory::PROVIDER_CLASSES.keys
    end

    # Implemented providers whose class declares embedding capability — feeds
    # the Organisation#embedding_provider whitelist, so a new embedding-capable
    # provider (google since the Vertex slice) becomes selectable without
    # touching a hardcoded list.
    def embedding_capable_providers
      Lalabase::Llm::Factory::PROVIDER_CLASSES.select { |_name, klass| klass.supports_embeddings? }.keys
    end
  end

  # The name to put in front of an operator. Since P0 three EU presets all run
  # as provider openai_compatible, so `name` alone stops telling them apart —
  # `display_name` is what carries the difference, with `name` as the fallback
  # for rows predating the column. Public because the packages domain (selects,
  # badges, jurisdiction errors) needs the same string in four places.
  def display_label
    display_name.presence || name
  end

  # ── the two facts every caller needs about a credential, each stated ONCE ────
  #
  # Both used to be re-derived per call site, and each rule had a site that got it
  # wrong: the endpoint was read four ways (three via the column, one via the legacy
  # JSON alone), and the purpose was asked on the embedding lane but not on the chat
  # one. The wrong sites did not fail — they answered plausibly and differently, so a
  # customer saw "search unavailable" on a lane the Factory routed happily. One
  # definition each is the fix; the duplication was the defect.

  # The endpoint this credential actually talks to. Column FIRST, legacy
  # additional_config['uri_base'] second: the column is where S2 put it and where all
  # three EU presets write, the JSON key only serves rows predating it.
  # @return [String, nil]
  def effective_api_base
    api_base.presence || additional_config&.dig('uri_base')
  end

  # Does this credential's PURPOSE cover the given lane? The vocabulary itself lives
  # in AiCredentialPricing — this is the lane-shaped question asked of it, so no
  # caller has to know which constant answers for which lane.
  # @param lane [Symbol] :chat or :embedding
  def serves_lane?(lane)
    case lane
    when :chat      then AiCredentialPricing::CHAT_PURPOSES.include?(purpose)
    when :embedding then AiCredentialPricing::EMBEDDING_PURPOSES.include?(purpose)
    else raise ArgumentError, "Unknown lane #{lane.inspect}"
    end
  end

  # openai_compatible has no vendor default to fall back on — without an endpoint the
  # provider raises at build time. Every other provider carries its own base URL, so
  # for them the question does not arise. `api_base` has no presence validation, so
  # this state is reachable on a perfectly valid row.
  def endpoint_resolvable?
    return true unless provider == ::AiCredential::PROVIDER_OPENAI_COMPATIBLE

    effective_api_base.present?
  end

  # "Can the routing actually run this lane on this credential?" — the three
  # conditions a gate and the resolution must agree on. Model-level checks only: no
  # network call, and nothing org-dependent (the model precedence stays with the
  # caller, because it reads org columns this object cannot see).
  def usable_for?(lane)
    enabled? && serves_lane?(lane) && endpoint_resolvable?
  end

  # Is the data residency of this credential STATED anywhere? The answer lives
  # in two different columns depending on provider: google/Vertex encodes it as
  # additional_config['location'] ('europe-west3'), everything else as the
  # coarse `region` select ('eu'/'us'). Both are nullable, so "nobody said" is a
  # real third state — and AiPackage's eu_native claim has to fail closed on it
  # (§9 Falle 6). Asking one column only would either miss Vertex or flag it.
  def residency_stated?
    return additional_config&.dig('location').present? if provider == ::AiCredential::PROVIDER_GOOGLE

    region.present?
  end

  private

  def implemented_provider?
    self.class.implemented_providers.include?(provider)
  end

  def provider_selection_changing?
    new_record? || will_save_change_to_provider?
  end

  def purpose_selection_changing?
    new_record? || will_save_change_to_provider? || will_save_change_to_purpose?
  end

  def activating?
    active? && (new_record? || will_save_change_to_active?)
  end

  def provider_must_be_implemented
    return if provider.blank? || implemented_provider?

    errors.add(:provider, :not_implemented)
  end

  def purpose_must_match_provider_capability
    return unless AiCredentialPricing::EMBEDDING_PURPOSES.include?(purpose)

    # Unimplemented providers are already rejected by rule 1 — no double error.
    provider_class = Lalabase::Llm::Factory::PROVIDER_CLASSES[provider]
    return if provider_class.nil? || provider_class.supports_embeddings?

    errors.add(:purpose, :embeddings_not_supported)
  end

  def activation_requires_implemented_provider
    return if implemented_provider?

    errors.add(:active, :provider_not_implemented)
  end

  def google_token_selection_changing?
    provider == ::AiCredential::PROVIDER_GOOGLE && access_token.present? &&
      (new_record? || will_save_change_to_access_token? || will_save_change_to_provider?)
  end

  def google_token_must_be_service_account_json
    parsed = JSON.parse(access_token)
    return if parsed.is_a?(Hash) && GOOGLE_SERVICE_ACCOUNT_KEYS.all? { |key| parsed[key].present? }

    errors.add(:access_token, :invalid_google_service_account)
  rescue JSON::ParserError
    errors.add(:access_token, :invalid_google_service_account)
  end
end
