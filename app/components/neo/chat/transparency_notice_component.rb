# frozen_string_literal: true

module Neo
  module Chat
    # Persistent AI transparency notice (Art. 13 GDPR / EU AI Act labelling):
    # content entered in the chat + project context is sent to the org's
    # provider. Extracted from ChatContainerComponent so the pages can place it
    # in their footer area (quiet, 2026-07-18 feedback) instead of inside the
    # chat flow — it must stay ON the page where the input happens.
    #
    # Everything stated here comes from ONE Factory.routing_disclosure call
    # (KI-Pakete P5): the legal notice must describe the routing the factory
    # will ACTUALLY perform — a second, local derivation (reading the org's
    # package or provider columns directly) could silently drift from it.
    class TransparencyNoticeComponent < ViewComponent::Base
      def initialize(organisation:)
        super()
        @organisation = organisation
      end

      # Customer-readable name of the provider chat answers go to.
      def ai_provider_display_name
        disclosure.chat_provider_label
      end

      # Embeddings route INDEPENDENTLY of chat (own BYOK lane in the factory).
      # When they go to a DIFFERENT provider than chat, the notice must name it
      # too — an Anthropic-chat org with default OpenAI embeddings sends input
      # to both, and naming only one would understate the recipients. Compared
      # by LABEL, not provider name: since P0 two different EU companies can
      # share the provider 'openai_compatible' (§3.4), and a name comparison
      # would hide the second recipient exactly there.
      def embedding_provider_display_name_if_different
        return nil if disclosure.embedding_provider_label == disclosure.chat_provider_label

        disclosure.embedding_provider_label
      end

      # The jurisdiction rung the org's curated package claims — the locale-key
      # fragment, translated in the template. nil (→ provider-only notice) when
      # no curated package governs the routing, for a package that neither
      # derives nor claims a rung (the notice's added value over the provider
      # name IS the jurisdiction, so without one there is nothing to add) —
      # and while the search is NOT served by the package's own lane: during a
      # staged switch every query input still flows to the old space, and a
      # jurisdiction line over that would be a false claim, not an
      # understatement (pre-landing review, KRITISCH 1). The embedding
      # addendum keeps naming the still-serving recipient either way.
      def package_jurisdiction
        return nil unless disclosure.search_on_package_lane

        disclosure.package.effective_jurisdiction.presence
      end

      # Only stated alongside a jurisdiction claim: on its own, a region string
      # is exactly the "EU server" shorthand §3 exists to prevent.
      def package_processing_region
        return nil unless package_jurisdiction

        disclosure.package.processing_region.presence
      end

      private

      def disclosure
        @disclosure ||= Lalabase::Llm::Factory.routing_disclosure(@organisation)
      end
    end
  end
end
