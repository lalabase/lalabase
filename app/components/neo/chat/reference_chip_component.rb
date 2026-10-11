# frozen_string_literal: true

module Neo
  module Chat
    # The reference chip (Bezugs-Sammlung S1, plan §8.1): WHICH objects this
    # thread is about. "Bezug: #112 Anmeldung schlaegt fehl", next to the scope
    # chip that says where the assistant looks.
    #
    # The exact mirror image of ScopeChipComponent's render rule, and not the
    # same control: the scope chip is a select because AssistantScopeOptions can
    # enumerate its projects. Referenceable objects cannot be enumerated -- a
    # reference is SET from the object itself (a button in its header) and here
    # only ever REMOVED. So: a label and a remove button, no chooser.
    #
    # THREE states (S2, plan §8.1): nothing, the pill of today, and from two
    # entries on a <details> whose summary counts them by type ("Bezug: 2
    # Aufgaben, 3 Gespraeche"). The pattern is not new -- CitationListComponent
    # collapses the source list the same way, with no JavaScript at all.
    #
    # ⚠️ The ENTRY markup is written ONCE (captured in the template) and only its
    # wrapper changes. A pill for one and a visually different row for many would
    # be two shapes to keep in step, and this row already carries the icon, the
    # title cap and the remove address per entry.
    #
    # What it shows is the RESOLVED collection, never the stored column: an object
    # whose project was archived, whose access was taken away, or which moved to
    # another organisation stops being a reference. It then renders NOTHING rather
    # than naming it -- a name is exactly what this app withholds from someone
    # without access, so an unresolvable reference leaves no trace here either
    # (same rule as in the system prompt, see ChatResponseJob#reference_hint).
    #
    # The DOM id is derived from the chat, never fixed: two surfaces of this app
    # can render chat components into ONE document, and a fixed id in that
    # situation is how a turbo_stream replace ends up hitting the wrong copy.
    class ReferenceChipComponent < ViewComponent::Base
      # The title is free text and can be a pasted stacktrace. Capped HERE as
      # well as in the prompt, because "the CSS truncates it" is a promise about
      # the viewport, not about the string: the tooltip and the accessible name
      # carry the untruncated value.
      MAX_TITLE_CHARS = 80

      # scope: the already-resolved reach, passed by ScopeRowComponent so both
      # chips share one. nil means "resolve your own" -- this component stays
      # renderable on its own.
      def initialize(chat:, current_user:, current_organisation:, scope: nil, expanded: false)
        super()
        @chat = chat
        @current_user = current_user
        @current_organisation = current_organisation
        @scope = scope
        @expanded = expanded
      end

      def render?
        return false unless @chat&.persisted? && @chat.org_thread?
        return false unless @current_user.present? && @current_organisation.present?

        references.any?
      end

      def dom_id
        "#{ActionView::RecordIdentifier.dom_id(@chat)}_reference_chip"
      end

      # The ONE resolution, shared with the tools and the prompt
      # (Lalabase::Tools::Scope#references). No second check by hand: the question
      # "may this reference still stand for THIS asker?" has an owner.
      def references
        @references ||= scope&.references || []
      end

      def scope
        @scope ||= Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user)
      end

      # What the thread points at right now, as the composite keys of §7.1. The
      # panel reads the DOM here because it is the only channel it has: its own
      # node is permanent, the server never re-renders it, and the chip is what
      # the server said LAST. Space-separated so the panel can compare the whole
      # string (that is how it tells a refused write from a landed one) and still
      # ask about a single key.
      #
      # ⚠️ Built from the RESOLVED collection, like everything else here. An entry
      # that leaves no chip must leave no key either, or the panel reads a
      # membership the user cannot see and stays quiet where it should offer.
      def reference_keys
        @reference_keys ||= references.map { |record| Assistant::ReferenceRegistry.key_of(record) }.join(' ')
      end

      # From two entries on the list collapses. One entry stays the pill it always
      # was: a disclosure over a single item would hide behind a summary the very
      # text the summary would have to show.
      def collection?
        references.size > 1
      end

      # ⚠️ Rendered `open` when the request that produced this row was a reference
      # write (plan §8.1). The disclosure state is DOM state, and the whole row is
      # REPLACED by turbo_stream after every write -- so what the server renders
      # IS the state afterwards. The cross sits inside the open list, which makes
      # this the difference between removing three entries in four clicks and in
      # seven. Both writes count, adding and removing: "a reference write leaves
      # the list open" is a rule, "open on add, closed on remove" is a case
      # distinction that has to be got right in the controller, the template and
      # the cell.
      def expanded?
        @expanded
      end

      # "2 Aufgaben", or "1 Aufgabe, 3 Gespraeche" once a second type is
      # registered. Counted over the RESOLVED collection like everything else
      # here: a number read off the stored column would announce entries the asker
      # cannot see and cannot remove.
      #
      # In REGISTRY order, not in the order the entries happen to be stored: the
      # summary is a description of the collection, and a description that
      # reshuffles itself when an entry is added reads as a different collection.
      def summary_label
        counts = references.group_by { |record| record.class.name }.transform_values(&:size)

        Assistant::ReferenceRegistry.types.filter_map do |type|
          count = counts[type]
          next if count.nil?

          t("views.organisations.assistant_panels.reference.types.#{citation_type_of(type)}", count: count)
        end.join(', ')
      end

      # The glyph of the type, from the map that ALREADY answers "what does a
      # ticket look like in a list" (CitationListComponent::ICON_MAP), reached
      # through the registry's `citation_type`. A map of our own here would be the
      # fourth card §2.3 of the plan exists to prevent, and it would drift the
      # first time a type changes its icon.
      #
      # The fallback is unreachable while the registry guard holds (T-2 pins
      # citation_type into Citations::TYPES, and ICON_MAP.keys is pinned to the
      # same list). It stays because this renders in the companion panel on EVERY
      # page: a KeyError here is a 500 everywhere, and a bookmark glyph is the
      # cheaper way to be wrong.
      def icon_for(record)
        CitationListComponent::ICON_MAP.fetch(
          citation_type_of(record.class.name), CitationListComponent::FALLBACK_ICON
        )
      end

      # "#112 Anmeldung schlaegt fehl", through the type's own formatter (the
      # registry's `title` lambda). Only the NUMBER is this surface's own: 80 is
      # what a 380px pill can carry, the prompt's sentence affords more.
      def title_for(record)
        Assistant::ReferenceRegistry.entry_for(record.class.name).title.call(record, MAX_TITLE_CHARS)
      end

      def remove_url(record)
        helpers.organisation_assistant_chat_reference_path(
          @current_organisation, @chat, Assistant::ReferenceRegistry.key_of(record)
        )
      end

      private

      def citation_type_of(type)
        Assistant::ReferenceRegistry.entry_for(type).citation_type
      end
    end
  end
end
