# frozen_string_literal: true

module Neo
  module Ai
    # THE box a surface shows in place of an AI control it has to withhold.
    #
    # It owns the LOOK only. The sentence comes from
    # Lalabase::Llm::FeatureRegistry.unavailable_hint — one text source for the whole
    # reason set (R3) — and the routing question was already answered by the caller's
    # organisation.ai_available_for?(:key).
    #
    # Why a component and not eight copies of a div: R4 moves thirteen opt-in-only
    # surfaces onto the feature gate and every one of them needs the same box AND the
    # same "stay silent about the opt-in" rule. Written out per call site that rule is
    # eight hand-enforced copies of `reason != :ai_disabled` — the duplicated-enforcement
    # signal from CLAUDE.md, and the kind of line that is silently wrong at the ninth
    # site. Here it is one predicate with one test.
    #
    # THE OPT-IN DEFAULT (plan §6, R4): a surface that shows nothing today when the org
    # has not opted in must keep showing nothing — R4 only replaces switches that are
    # useless because a CONFIGURATION is missing. Surfaces that already explain the
    # opt-in today (the chat composer, the empty chat list) keep doing so and say
    # explain_opt_in: true. That is the R3 division of labour: the registry decides WHAT
    # a reason says, the caller decides WHETHER it is spoken.
    class UnavailableHintComponent < ViewComponent::Base
      # :plain carries no box at all — it exists because two surfaces already showed
      # this sentence before R4 as a quiet paragraph, and turning their opt-in notice
      # into a bordered panel would be a visual change R4 did not set out to make.
      VARIANTS = {
        info: { container: 'p-3 rounded border-2 border-stroke bg-cobalt-50 text-sm text-gray-800',
                icon: 'bi-info-circle text-cobalt-700' },
        warning: { container: 'p-3 rounded border-2 border-stroke bg-amber-50 text-sm text-gray-800',
                   icon: 'bi-shield-exclamation text-amber-700' },
        plain: { container: 'text-sm text-cream-900 opacity-70', icon: nil }
      }.freeze

      # @param availability [Lalabase::Llm::FeatureRegistry::Availability, nil] the answer
      #   from organisation.ai_available_for?; nil means "no organisation at all", which
      #   renders nothing (the caller's own nil branch stays out of the template).
      # @param organisation [Organisation, nil] interpolation source for the sentence.
      # @param feature [Symbol, nil] registry key. Names the withheld feature above the
      #   sentence — needed wherever two lanes sit in ONE form (the document forms), where
      #   a bare reason cannot say WHICH checkbox went away.
      # @param variant [Symbol] :info (default), :warning or :plain.
      # @param explain_opt_in [Boolean] see the class comment. Default false.
      # @param classes [String, nil] outer spacing so the box sits where the control sat.
      def initialize(availability:, organisation:, feature: nil, variant: :info,
                     explain_opt_in: false, classes: nil)
        super()
        @availability = availability
        @organisation = organisation
        @feature = feature
        @variant = VARIANTS.key?(variant) ? variant : :info
        @explain_opt_in = explain_opt_in
        @classes = classes
      end

      # Defence in depth against a caller that renders us for a working feature: an empty
      # bordered box next to a live checkbox is worse than no box at all.
      #
      # A nil availability counts as :ai_disabled, not as its own case — that is what the
      # registry itself answers for a nil organisation, and unavailable_hint returns the
      # opt-in copy for both. Treating nil as "render nothing" instead would quietly drop
      # the notice the chat composer has always shown when it is built without an org.
      def render?
        return false if @availability&.available?
        return false if opt_in_only? && !@explain_opt_in

        true
      end

      def message
        Lalabase::Llm::FeatureRegistry.unavailable_hint(@availability, @organisation)
      end

      # Guard-enforced to exist in DE AND EN for every registry entry, so this cannot
      # render a raw key (see the locale comment above shared.ai.features).
      def feature_label
        return nil if @feature.blank?

        t("shared.ai.features.#{@feature}")
      end

      def opt_in_only?
        @availability.nil? || @availability.reason == :ai_disabled
      end

      # The flex row exists to seat the ICON beside the text, so it is conditional on
      # there being one. Unconditionally it defeated :plain, whose whole job is to leave
      # the quiet paragraph looking exactly as it did: its only call site sits inside a
      # `text-center` empty state, where turning a <p> into a flex container makes the
      # sentence a shrink-to-fit item at flex-start — left-aligned where it used to be
      # centred. gap-2 was dead there too (no icon, a single child).
      def container_classes
        flex = 'flex items-start gap-2' if icon_classes
        [@classes, VARIANTS.fetch(@variant)[:container], flex].compact.join(' ')
      end

      # nil for :plain — the template then renders the sentence without an icon.
      def icon_classes
        VARIANTS.fetch(@variant)[:icon]
      end
    end
  end
end
