# frozen_string_literal: true

module Neo
  module Chat
    # The row of what the assistant is pointed at (S4 T2 step 4, plan §7.3):
    # the scope chip (which projects) and the reference chip (which object).
    #
    # It exists to be the TURBO ANCHOR, which is why it renders an empty element
    # when neither chip applies -- its render? asks only whether an anchor is
    # possible at all, never whether there is something to show. Both chips hide
    # themselves, and a chip that hides itself leaves nothing behind: removing the
    # reference would delete the very element the next request wants to replace,
    # and turbo_stream.replace on an id that is no longer in the document does
    # nothing at all -- silently. Step 5 (the button in the ticket header) puts a
    # chip back into exactly this spot, so the spot has to survive being empty.
    #
    # It is also the reason there is ONE stream instead of two: the ticket button
    # sets the reference AND the project, so both chips change in one request.
    #
    # Id derived from the chat, never fixed (the panel renders chat components on
    # top of whatever page the user is on).
    class ScopeRowComponent < ViewComponent::Base
      # reference_expanded: the one piece of REQUEST knowledge the chips cannot
      # have -- whether the request that produced this row was a reference write,
      # and the collection should therefore come back unfolded (§8.1). Passed
      # through rather than decided here: the row knows nothing about what the
      # collection looks like, and the chip knows nothing about who asked.
      def initialize(chat:, current_user:, current_organisation:, reference_expanded: false)
        super()
        @chat = chat
        @current_user = current_user
        @current_organisation = current_organisation
        @reference_expanded = reference_expanded
      end

      # The ONE thing that can take the anchor away: there is no anchor worth
      # having for an unsaved chat. dom_id would answer "new_chat_scope_row" for
      # every such render, and a FIXED dom id is the trap this feature has hit
      # three times, the last one in production (#612). The chips gate on
      # persisted? too; this is the same gate, one level up.
      def render?
        @chat&.persisted? || false
      end

      def dom_id
        "#{ActionView::RecordIdentifier.dom_id(@chat)}_scope_row"
      end

      # Reference first, scope second: the object is the subject of the question,
      # the reach is the qualifier -- and the reference is the one the user just
      # set by arriving from a ticket.
      def reference_chip
        ReferenceChipComponent.new(**chip_args, expanded: @reference_expanded)
      end

      def scope_chip
        ScopeChipComponent.new(**chip_args)
      end

      private

      # ONE reach resolution for both chips. Each chip can still build its own
      # (they are renderable alone, and the factory guard keeps them on
      # Tools::Scope.for), but rendered through this row they share this one:
      # resolving twice means asking accessible_project_ids twice and plucking
      # the active projects twice, on a panel that renders on every page.
      #
      # Tools::Scope already memoizes area_reach internally for exactly this
      # reason. This is the same thought one level up.
      def scope
        @scope ||= Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user)
      end

      def chip_args
        { chat: @chat, current_user: @current_user,
          current_organisation: @current_organisation, scope: scope }
      end
    end
  end
end
