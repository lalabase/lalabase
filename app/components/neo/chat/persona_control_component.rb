# frozen_string_literal: true

module Neo
  module Chat
    # The requesting person's standing persona choice, as one auto-submitting
    # select in the assistant's settings (gear icon in the panel header).
    #
    # Same shape as the scope chip and the style selects, deliberately: the
    # browser's own control shows the chosen value and nothing else, handles the
    # keyboard and touch without a line of JavaScript, and three different shapes
    # for three settings of one answer would read as three unrelated controls.
    #
    # The blank option is not padding -- it is the state "no standing choice", in
    # which the organisation's default persona applies. Somebody who picked one and
    # wants back out needs a way to say so, and clearing the choice is that way.
    class PersonaControlComponent < ViewComponent::Base
      # Turbo-stream replace target, shared with the update turbo_stream view so it
      # cannot drift. A CLASS, not an id, and not because two copies exist today:
      # this feature has shipped the fixed-id bug three times (last in production),
      # and the panel is precisely the surface that renders chat controls on top of
      # a page that may hold its own. replace_all over a class moves every copy;
      # an id promises one element and silently updates whichever comes first.
      DOM_CLASS = 'assistant-persona-choice'

      def initialize(current_user:, current_organisation:)
        super()
        @current_user = current_user
        @current_organisation = current_organisation
      end

      # No pool, nothing to choose, so nothing to render -- the settings view says
      # why instead. Same rule the scope chip applies: a control that cannot change
      # anything is noise in a panel 380px wide.
      #
      # ONE persona is already a real choice, unlike the chip's two-project rule:
      # the blank option means "the org default", and where the pool was never
      # seeded that default is nothing at all. Picking the single persona therefore
      # changes the answer.
      def render?
        @current_user.present? && @current_organisation.present? && options.any?
      end

      def dom_class
        DOM_CLASS
      end

      def options
        @options ||= PromptPersona.pickable_for(@current_organisation)
      end

      # What the control SHOWS: the resolved choice, never the stored column. A
      # persona retired org-wide after somebody picked it is no longer a choice,
      # and the select must fall back to the blank option the same moment the job
      # falls back to the default -- otherwise it names a persona that is no longer
      # being used.
      def selected_id
        preference.resolved_persona&.id
      end

      def update_path
        helpers.organisation_assistant_preference_path(organisation_id: @current_organisation.id)
      end

      # Read-only resolve: never writes a row just because somebody opened the
      # settings (ChatStylePreference.resolve_for returns an unpersisted default).
      def preference
        @preference ||= ChatStylePreference.resolve_for(user: @current_user, organisation: @current_organisation)
      end
    end
  end
end
