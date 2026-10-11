# frozen_string_literal: true

module Neo
  module Chat
    # The scope chip (S3a T5, plan §9.3): what the assistant looks at when it
    # answers. "Alle Projekte" or one of them, stored on the thread, visible at
    # the input field.
    #
    # Only ever a NARROWING: "Alle Projekte" means every project the asker may
    # read, never the organisation's whole list. The wording says "deine", so the
    # chip does not promise a reach it does not have.
    #
    # Org threads only, which since projekt_chat_abbau is every thread. The chip was
    # never offered on the surface that cut removed: it already WAS one project, so
    # narrowing it had no width to work on.
    #
    # The DOM id is derived from the chat rather than fixed. Two surfaces of this
    # app can render chat components into ONE document (the companion panel sits
    # on top of every page, chat pages included), and a fixed id in that situation
    # is how a turbo_stream replace ends up hitting the wrong copy -- twice
    # already in this feature.
    class ScopeChipComponent < ViewComponent::Base
      # scope: the already-resolved reach, passed by ScopeRowComponent so both
      # chips share one. nil means "resolve your own" -- this component stays
      # renderable on its own.
      def initialize(chat:, current_user:, current_organisation:, scope: nil)
        super()
        @chat = chat
        @current_user = current_user
        @current_organisation = current_organisation
        @scope = scope
      end

      # Also: only where there is something to choose. With a single readable
      # project "all your projects" and "that project" are the same set, so the
      # control cannot narrow anything -- and a row that says "Sucht in: Allen
      # deinen Projekten" next to an organisation that HAS one project is a line
      # of noise in a panel that is 380px wide by default.
      def render?
        return false unless @chat&.persisted? && @chat.org_thread?
        return false unless @current_user.present? && @current_organisation.present?

        options.size > 1
      end

      def dom_id
        "#{ActionView::RecordIdentifier.dom_id(@chat)}_scope_chip"
      end

      # The projects offerable here, from the ONE owner the write path validates
      # against (Chats::AssistantScopeOptions) -- read through the scope, which
      # memoizes that same list as #offerable_projects and is what #selection
      # resolves against. Asking the owner twice was not only a second query: the
      # option list came from @current_organisation while the selection came from
      # the CHAT's organisation, so the two could in principle disagree about
      # which list a stored id is measured against.
      #
      # The direct call stays as the fallback for a nil scope (a project thread);
      # render? turns this component away before that, so it is a totality
      # guarantee, not a second path.
      def options
        @options ||= scope&.offerable_projects ||
                     Chats::AssistantScopeOptions.call(user: @current_user, organisation: @current_organisation)
      end

      # What the chip SHOWS: the resolved selection, not the stored column. A
      # project that has since been archived or lost its read right is no longer a
      # narrowing (Tools::Scope#selection), and the chip has to say so the moment
      # it happens instead of naming a restriction that no longer holds.
      def selected_project
        return @selected_project if defined?(@selected_project)

        @selected_project = scope&.selection
      end

      def scope
        @scope ||= Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user)
      end

      def form_url
        helpers.organisation_assistant_chat_path(@current_organisation, @chat)
      end
    end
  end
end
