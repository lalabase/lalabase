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
    #
    # The two tools have MCP twins (McpFindPeople, McpGetPerson, People S3b) with the same
    # answers, which name the organisation themselves; with_token_lookup is their part.
    class PeopleTool < Base
      REFUSAL = 'The asking user may not see the people directory of this organisation. Say so, ' \
                'and do not guess names or contact details.'

      # The organisation of an MCP call, always named (S3b E3): a token may reach several.
      ORGANISATION_ID_SCHEMA = {
        organisation_id: { type: 'string',
                           description: 'UUID of the organisation whose people directory to read ' \
                                        '(list_organisations names each organisation in reach).' }
      }.freeze

      TOKEN_NOTE = 'Both people tools take the organisation_id of the directory they read. Only a token ' \
                   'that reaches every project of that organisation reads its directory; for a token ' \
                   'limited to some projects the organisation is not found.'

      # list_notifications' wording for an organisation filter it cannot honour, so a missing
      # organisation, one outside the token and one the token reaches only in some projects
      # read alike on both.
      ORGANISATION_NOT_REACHABLE = Notifications::InboxQuery::ORGANISATION_NOT_REACHABLE

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

      # The schema of an MCP twin: the assistant's, with the organisation in front.
      def self.with_organisation_id(schema)
        schema.merge(properties: ORGANISATION_ID_SCHEMA.merge(schema[:properties]),
                     required: ['organisation_id', *schema[:required]])
      end

      # What an MCP twin does before it reads (People S3b). No project gate ran (scope_mode
      # :token), so this is the gate: the organisation must be one whose every project the
      # token reaches (E1, People::Lookup.for_token), else not found like an organisation
      # outside it; the call runs under that organisation's tenant; the people right comes
      # next (refused); and the decision is marked for the D7 tripwire. PersonPolicy#index?
      # reads the tenant, so a call that ran without it would be turned away (forbidden), not
      # served.
      def self.with_token_lookup(args, context)
        return Result.new(error: 'token context missing') unless token_wide?(context)

        raw = symbolized(args)[:organisation_id].to_s.strip
        return Result.invalid_input('organisation_id is required') if raw.empty?
        return Result.invalid_input("invalid organisation_id #{raw.inspect} (expected a UUID)") unless Lalabase::Uuid.valid?(raw)

        people = People::Lookup.for_token(reach: context.reach, viewer: context.actor, organisation_id: raw)
        return Result.new(error: ORGANISATION_NOT_REACHABLE, code: :not_found) if people.nil?

        ActsAsTenant.with_tenant(people.organisation) do
          next refused unless people.allowed?

          authorize!(context, Person, :index?)
          yield people
        end
      end
    end
  end
end
