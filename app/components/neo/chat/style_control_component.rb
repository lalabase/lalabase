# frozen_string_literal: true

module Neo
  module Chat
    # The requesting user's persistent chat answer-style level (technicality /
    # length, three steps each) as two compact selects under the composer. The
    # selected option IS the stored state -- display and control are the same
    # element, which is why there is no separate level readout and no reset link
    # (resetting = picking the middle step).
    #
    # Selects and no longer a row of pills (27.08.2026): six pills spelled out
    # every step of both dimensions permanently, which is five pieces of
    # information more than the answer to "how is it set right now" needs, on a
    # panel that is 380px wide by default. The browser's own control shows the
    # chosen step and nothing else, and it handles the keyboard and touch without
    # a line of JavaScript. Same shape as the scope chip (ScopeChipComponent) for
    # exactly the reason that one gives: these are settings of ONE answer, and
    # three different shapes would read as three unrelated controls.
    #
    # Picking a level only SETS it; it triggers no answer and costs no AI quota.
    # A control below the message field reads as "for what I write next", so
    # regenerating the previous answer off it would be ambiguous -- that is the
    # explicit regenerate action on the answer itself (MessageComponent).
    #
    # Per-user-per-org, so it is rendered per request (where current_user is
    # present), NOT in the viewer-agnostic streaming broadcast. The update action
    # turbo_stream-replaces this by its stable DOM class, so the selection moves
    # right after a change.
    class StyleControlComponent < ViewComponent::Base
      # Turbo-stream replace target, shared with the update turbo_stream view so
      # it can't drift. A CLASS, not an id: since the companion panel (S3a T4) the
      # control exists TWICE in a document whenever the panel is open on a chat
      # page. An id promises one element; turbo_stream.replace resolves it with
      # getElementById and hits whichever comes first, so a change in the panel
      # updated the page's control and left the panel showing the old state.
      # The preference is per user and per org, so every copy is meant to move --
      # which is what replace_all over a class does and an id cannot.
      DOM_CLASS = 'chat-style-level'

      # Dimension → the I18n leaf holding its per-level labels. Both leaves
      # already exist (einfach/mittel/technisch, knapp/mittel/ausführlich).
      I18N_SCOPE = 'views.organisations.chats.style_level'

      # The scope chip's outline, deliberately. text-xs explicitly and
      # focus:ring-0 for the reason documented there: form controls do not
      # inherit font-size (@tailwindcss/forms sets them to 1rem), and the
      # plugin's blue focus ring is the browser's language, not this app's.
      # pe-7 and not a plain px-2.5: @tailwindcss/forms paints the select's own
      # arrow into the inline-end padding it sets, and overriding that padding on
      # both sides puts the arrow straight on top of the last letter of the value.
      SELECT_BASE = 'rounded-full border ps-2.5 pe-7 py-0.5 text-xs transition-colors ' \
                    'focus:outline-none focus:ring-0'
      # Highlighted only where the stored level DIFFERS from the neutral middle
      # step -- the same grammar the scope chip uses for "all your projects"
      # versus one chosen project. A control sitting on its default has nothing
      # to announce, and a row in which everything is emphasised emphasises
      # nothing.
      SELECT_CHOSEN = 'border-ink bg-cream-200 text-cream-900 font-semibold'
      SELECT_NEUTRAL = 'border-cream-300 bg-cream-50 text-cream-700 hover:bg-cream-100 hover:border-cream-400'

      def initialize(current_user:, current_organisation:)
        super()
        @current_user = current_user
        @current_organisation = current_organisation
      end

      # Degrade silently if rendered without a user/org (e.g. a broadcast context).
      def render?
        @current_user.present? && @current_organisation.present?
      end

      def dom_class
        DOM_CLASS
      end

      def dimensions
        ChatStylePreference::DIMENSIONS
      end

      def levels
        ChatStylePreference::LEVELS
      end

      def group_label(dimension)
        t("#{I18N_SCOPE}.dimensions.#{dimension}")
      end

      def level_label(dimension, level)
        t("#{I18N_SCOPE}.#{dimension}.#{level}")
      end

      # [label, value] pairs for options_for_select. Every step stays reachable --
      # the control shows one and offers three.
      def level_options(dimension)
        levels.map { |level| [level_label(dimension, level), level] }
      end

      def selected_level(dimension)
        pref.public_send(dimension)
      end

      # The neutral middle step, from the model's own default rather than a
      # literal 2 here: the step that means "nothing special" has an owner.
      def default_level(dimension)
        ChatStylePreference::DEFAULT.fetch(dimension.to_sym)
      end

      def chosen?(dimension)
        selected_level(dimension) != default_level(dimension)
      end

      # The dimension travels in the URL, the level in the field -- the update
      # action reads both off params and is unchanged by this control's shape.
      def update_path(dimension)
        helpers.organisation_chat_style_preference_path(@current_organisation, dimension: dimension)
      end

      def select_classes(dimension)
        "#{SELECT_BASE} #{chosen?(dimension) ? SELECT_CHOSEN : SELECT_NEUTRAL}"
      end

      private

      # resolve_for is read-only and never persists, so rendering this control can
      # never create a row. We pass @current_organisation explicitly rather than
      # leaning on ActsAsTenant.current_tenant: the org this component shows is the
      # one it was handed, the dependency stays visible (easy to test in isolation),
      # and it can't silently render another org's level if the ambient tenant ever
      # differs from the component's org. Memoised -- pref is read once per select.
      def pref
        @pref ||= ChatStylePreference.resolve_for(user: @current_user, organisation: @current_organisation)
      end
    end
  end
end
