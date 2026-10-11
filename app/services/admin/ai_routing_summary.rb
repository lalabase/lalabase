# frozen_string_literal: true

# Which AI an organisation's CHAT actually runs on, in operator vocabulary:
# the credential behind it, the model, and — on a package — the rung.
#
# Entry point: .for
#
# Exists because the admin overview used to answer a NARROWER question than it
# looked like: `has_own_ai_credentials?` says "the org brought no token", and
# that was rendered as "System-Credentials" — which is wrong for every curated
# org, since a package routes through the credential the PACKAGE names, not
# the provider's active system row.
#
# GATE-FREE by design: the admin question is "which AI would this org's chat
# use", not "may it call right now". An org with the DSGVO opt-in switched off
# still has a resolved routing, and answering nil there would hide exactly the
# setup an operator opens this page to check.
#
# The resolution ORDER is not redecided here — package rung > BYOK > system
# credential belongs to Lalabase::Llm::Factory, and the two branches it can
# answer cheaply are asked THROUGH it. Only the last step (naming the active
# system credential) reads AiCredential directly, the same cached lookup
# Factory#resolve_credentials makes: resolving through the factory would
# decrypt a token and raise on a missing credential, and a display path must
# do neither.
module Admin
  class AiRoutingSummary
    # source — where the routing comes from:
    #   :package — the org's curated package names credential + rung
    #   :byok    — the org's own token (terminal, never falls back to :system)
    #   :system  — the provider's active system credential
    #   :none    — nothing resolvable; every AI call would raise
    # broken — we HAVE a credential and it cannot serve chat (disabled, wrong
    #   purpose, no endpoint). Deliberately false on :byok: there is no
    #   credential row to judge, and the token itself is not readable here.
    Summary = Struct.new(:source, :label, :model, :package, :tier, :broken, keyword_init: true)

    def self.for(organisation)
      new(organisation:).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    def call
      tier = ::Lalabase::Llm::Factory.curated_chat_tier(@organisation)
      return package_summary(tier) if tier

      return byok_summary if own_token?

      system_summary
    end

    private

    def package_summary(tier)
      credential = tier.chat_credential
      Summary.new(
        source: :package,
        label: credential&.display_label,
        model: tier.effective_chat_model,
        package: tier.ai_package,
        tier: tier,
        broken: credential.nil? || !credential.usable_for?(:chat)
      )
    end

    def byok_summary
      Summary.new(
        source: :byok,
        label: @organisation.ai_provider_display_name,
        model: @organisation.try(:preferred_chat_model).presence,
        broken: false
      )
    end

    def system_summary
      credential = ::AiCredential.active_for_provider(provider_name)
      return Summary.new(source: :none, broken: true) if credential.nil?

      Summary.new(
        source: :system,
        label: credential.display_label,
        model: credential.default_model.presence,
        broken: !credential.usable_for?(:chat)
      )
    end

    # BYOK is provider-aware, not merely "a token is present": a token saved for
    # anthropic says nothing about an org whose provider column now reads openai
    # — Factory#resolve_credentials would walk past it to the system credential,
    # and so must this summary. Asked through the org's own predicate so the
    # rule has one definition (Admin::Organisation mirrors it).
    def own_token?
      @organisation.has_own_ai_credentials?(provider_name)
    end

    def provider_name
      @provider_name ||= ::Lalabase::Llm::Factory.chat_provider_name(@organisation)
    end
  end
end
