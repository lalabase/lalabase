# frozen_string_literal: true

module Lalabase
  module Tools
    # What the two tools that read the people directory share (People S3): find_people lists
    # people, get_person reads one. Both read through People::Lookup (People S3b), the one read
    # of the directory that the MCP tools and the REST endpoints share with them: the rights,
    # the search, the id format and the field selection live there, not here. No Person.where,
    # no Person.find.
    #
    # Rights come first: the people right is asked before anything is read, and its absence is a
    # refusal the model can say out loud instead of "nobody found". It also asks for an ACTIVE
    # membership, so a deactivated member who still holds the right is refused too. The
    # assistant's own gates (ai_enabled, assistant_enabled, the quota) stay where they are; the
    # directory has no switch of its own (decision E1).
    #
    # The directory belongs to the organisation, not to a project: like the help tools these
    # take no project, report no coverage and filter by no project. Their citations carry the
    # people area (Citations.person), which keeps an answer drawn on them with the asker.
    #
    # Which fields reach the AI provider is decided in People::Lookup.row and .card, never the
    # notes (decision E2).
    class PeopleTool < Base
      REFUSAL = 'The asking user may not see the people directory of this organisation. Say so, ' \
                'and do not guess names or contact details.'

      # Reads context.actor for the rights and the directory, so the Runner's fail-closed bar
      # applies: a thread without an asker gets no person data.
      def self.requires_actor?
        true
      end

      # The asker's directory in the thread's organisation.
      def self.lookup(context)
        People::Lookup.new(viewer: context.actor, organisation: context.organisation)
      end

      def self.refused
        Result.refused(REFUSAL, reason: :people_directory)
      end
    end
  end
end
