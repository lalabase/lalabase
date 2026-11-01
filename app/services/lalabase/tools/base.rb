# frozen_string_literal: true

module Lalabase
  module Tools
    # Abstract base for LLM-callable tools. Concrete tools live in
    # app/services/lalabase/tools/ and override the four class methods below.
    #
    # Tools are STATELESS — there is no Tool#initialize. The Runner calls
    # SubclassName.execute(args:, context:) directly. This keeps Registry
    # introspection cheap and avoids per-call object allocation.
    class Base
      # Strict UUID match (dashed 8-4-4-4-12 or 32-char hex). Tools validate an id
      # argument against this before find_by, so a hallucinated non-UUID id returns
      # a clean tool error instead of crashing on PG::InvalidTextRepresentation.
      # Owner: Lalabase::Uuid (shared with the inbox query).
      UUID_FORMAT = Lalabase::Uuid::FORMAT

      # What a cut text ends in, so a truncated attachment, note, document or meeting is
      # recognisable as the same thing as a truncated ticket body. One marker for
      # every read tool; the LIMIT stays each tool's own.
      TRUNCATION_MARKER = "\n\n…[truncated]"

      def self.tool_name
        raise NotImplementedError
      end

      # Cuts `value` to `limit` characters and appends the marker; nil stays nil.
      # Shared by every read tool that hands text to the model (GetTicket's body,
      # posts and attachments; GetNote and GetDocument's text; GetMeeting's notes
      # and transcript).
      def self.cap_text(value, limit)
        return value if value.nil?

        string = value.to_s
        return string if string.length <= limit

        string[0, limit] + TRUNCATION_MARKER
      end

      # What the thread POINTS AT may be read, even when the chip searches
      # elsewhere (Bezugs-Sammlung E3, review of #642). Answers the record of
      # `type` with `id` from the resolved reference collection, or nil.
      #
      # ⚠️ The state this exists for became routine with S2: setting a reference
      # no longer moves the scope chip, so "chip on project A, reference on an
      # object in B" now happens by doing nothing unusual. The system prompt then
      # names that object by title as the SUBJECT of the conversation, while the
      # tool's base scope, confined to A, answers "not found" -- and a model
      # holding the title answers from the title alone. A plausible answer about
      # an object nothing ever read is the worst of the three outcomes; the other
      # two (widen the search, or refuse the reference) each make one of the two
      # chips lie.
      #
      # NOT a second rights gate, and that matters (plan §13-9):
      #   * the reference passed Tools::Scope#resolve_reference when it was
      #     stored, which is the ONE owner of "may this object stand on this
      #     thread",
      #   * the caller still authorizes per record, so rights taken away since
      #     then still refuse there.
      # What widens is REACHABILITY, and only for objects the thread already
      # names. ⚠️ By UUID only, never by a human address (a ticket number is
      # unique per project, so resolving one through the references would answer
      # "which #1 did you mean" with an object the search was never allowed to
      # see).
      #
      # Shared by every record-reading tool of the assistant, because the rule
      # was enforced by hand in GetTicket first, and a second and third copy
      # would be a second and third place for it to drift.
      def self.referenced_record(context, type:, id:)
        # Compared as the collection's own composite key ("Note:<uuid>"), the ONE
        # vocabulary a reference is addressed by (Bezugs-Sammlung §7.1).
        wanted = Assistant::ReferenceRegistry.key_for(type: type, id: id)
        context.scope&.references&.find { |record| Assistant::ReferenceRegistry.key_of(record) == wanted }
      end

      # The coverage of an answer that read from BEYOND the reach (through
      # referenced_record). ⚠️ It REPLACES the chosen sentence rather than
      # decorating it: the call did not stay inside the chosen project, so
      # wearing its name is exactly the lie `outside` exists to prevent
      # (Scope#coverage_with). Set by the READER, from the read, because only the
      # call that actually fell back knows that it did.
      def self.outside_coverage(context, area:)
        context.scope.coverage_with(searched: context.scope.project_ids(area: area).size, outside: true)
      end

      def self.description
        raise NotImplementedError
      end

      # JSON-Schema hash describing the input arguments. Provider adapters
      # translate this into OpenAI's `function.parameters` / Anthropic's
      # `input_schema` wire format.
      def self.input_schema
        raise NotImplementedError
      end

      # @param args [Hash] symbolized keys, already coerced from JSON
      # @param context [Lalabase::Tools::Context] per-request chat/org/project
      # @return [Lalabase::Tools::Result]
      def self.execute(args:, context:)
        raise NotImplementedError
      end

      # Provider-neutral schema for Registry consumers.
      def self.to_schema
        {
          name: tool_name,
          description: description,
          input_schema: input_schema
        }
      end

      # Normalises a tool's args to a symbol-keyed Hash. The MCP ToolCall already
      # symbolizes, but a tool may also be called directly (e.g. in a unit test)
      # with string keys or a non-Hash — normalising here keeps every tool's
      # `args[:foo]` access valid without each tool repeating the guard.
      def self.symbolized(args)
        args.is_a?(Hash) ? args.symbolize_keys : {}
      end

      # The MCP ticket tools return their data as a pretty-printed JSON document in
      # the Result's text content (the MCP client parses it, vs. the prose the
      # code-context tools emit). Centralised so the "JSON, not prose" decision
      # lives in one place rather than in every tool.
      #
      # The payload is NOT fence-guarded here. This string is also the MCP wire
      # format (Mcp::ToolCall#result_to_response passes result.content through
      # verbatim), and a ticket description in a developer tool routinely contains
      # a real code fence — rewriting it would hand the client bytes it cannot turn
      # back, and a client writing them back via create_ticket would persist the
      # corruption. The fence guard belongs on the channel that actually builds a
      # fence, i.e. Runner#tool_result_message on the way into OUR model loop.
      #
      # `citations` is what the answer's rights gate runs on: an answer that drew
      # only on tool data with an empty citation list counts as content-free, and
      # Chatpost#gated_streaming? / MessageComponent#redacted? would then show it to
      # every chat reader regardless of their own rights. A tool returning content
      # a viewer may not see MUST cite it.
      #
      # `coverage` (S3a T3, L7): the org-wide reach of the answer as
      # {searched:, total:} projects — see Result. nil on single-project calls.
      def self.json_result(payload, citations: [], coverage: nil)
        Result.new(content: JSON.pretty_generate(payload), citations: citations, coverage: coverage)
      end

      # S3a T3 (Plan §9.1): true when this call runs with org-wide reach — an org
      # thread's Runner sets Context#scope and leaves project nil. Exactly one of
      # the two is ever set (Context contract), so tools branch on this single
      # predicate instead of re-deriving the rule per tool.
      def self.org_wide?(context)
        context.project.nil? && !context.scope.nil?
      end

      # The `project` filter of an org-wide call (S3a T5, §9.3), shared by every
      # tool that can reach more than one project. THREE tools need it, so both
      # the wording the model reads and the resolution behind it live here: three
      # copies of a description drift, and three copies of a rights-narrowing
      # rule is how this feature produced its worst defects.
      PROJECT_FILTER_SCHEMA = {
        project: { type: 'string',
                   description: 'Restrict to THIS project: its name as shown in the app ' \
                                '(e.g. "Nordlicht") or its UUID. Org-wide calls only. An ambiguous ' \
                                'or unknown name answers with a candidate list instead of a result, ' \
                                'so ask which one was meant rather than guessing.' }
      }.freeze

      # Returns nil (no filter), the resolved Project, or a Result the caller
      # returns INSTEAD of its own payload. The PROJECT and not its id, because
      # the answer's coverage sentence names it (T5 review): handing back the id
      # alone made every caller look the record up again, and the first one that
      # skipped that step is how the named sentence lost the filter.
      #
      # Refused outright on the single-project path: there the project is already
      # fixed by the caller (MCP's mandatory project_id), and
      # quietly ignoring the argument would let a model believe it narrowed
      # something it did not. R-M5 keeps that path untouched; this is what
      # untouched means in practice.
      #
      # `area` resolves the candidates through the per-area gate, which is right
      # for everything ProjectPermission knows about. `candidates` is for a tool
      # whose reach does NOT come from there: time sessions have no
      # `time_sessions` area at all (their all/own/none rule lives in
      # TimeSessions::ViewingScope, §2.4), so asking the area gate for it raises.
      # Exactly one of the two.
      def self.resolve_project_filter(args, context, area: nil, candidates: nil)
        # Loud rather than opaque: without this a fourth tool that forgets both
        # would reach project_ids(area: nil) and die on nil.to_sym, three frames
        # away from the mistake.
        raise ArgumentError, 'resolve_project_filter needs area: or candidates:' if area.nil? && candidates.nil?

        requested = args[:project].presence
        return nil if requested.nil?
        return Result.invalid_input('the project filter applies to org-wide calls only') if context.scope.nil?

        reachable = candidates || Project.where(id: context.scope.project_ids(area: area))
        resolved = ProjectResolver.call(requested, reachable: reachable)
        return resolved if resolved.is_a?(Project)

        coverage = candidates ? context.scope.coverage_with(searched: candidates.size) : context.scope.coverage(area: area)
        json_result(resolved, citations: [], coverage: coverage)
      end

      # The ONE project a CODE tool answers for (assistant code tools,
      # doc/assistent_code_werkzeuge_plan.md §A). Five tools need the same ladder,
      # and five copies of it would be five copies of a rights rule -- the mistake
      # this feature already made once.
      #
      # ⚠️ The five tools declare requires_actor? because of this method: the Runner
      # refuses a code tool on a thread whose history has no asker. Without an actor
      # the reach resolution would hand Pundit a nil, and the content retrieval is
      # already fail-closed for the very same reason.
      #
      # @return [Project] the project to answer for, or [Result] the caller returns
      #   INSTEAD of its own payload (a refusal, an empty answer, or a candidate list).
      def self.resolve_code_project(args, context)
        return single_project_code_target(args, context) unless org_wide?(context)

        # The ids and not a relation: `empty?` and `one?` below are decisions about
        # a list this scope already loaded, not three more round trips.
        ids = context.scope.code_project_ids
        return no_code_project_result(context) if ids.empty?

        candidates = Project.where(id: ids)
        # Rung 2: the question named a project. An ambiguous or unknown name answers
        # with the candidate list rather than a guess (ProjectResolver).
        return resolve_project_filter(args, context, candidates: candidates) if args[:project].presence

        # Rungs 3 and 4 are ONE rung here, because the chip already narrowed the
        # candidates (Scope#code_project_ids). "The person said which project" and
        # "there is only one" answer the same way, and folding them keeps a chip
        # from reaching code its owner may not read.
        return candidates.first if ids.one?

        # Rung 5: several reachable, nothing named. Vision and capabilities are 1:1
        # per project, so "all projects" has no meaning for three of the five tools,
        # and answering for the wrong one is worse than asking.
        json_result(ProjectResolver.candidates_payload(candidates), citations: [],
                                                                    coverage: context.scope.coverage_with(searched: ids.size))
      end

      # Rung 1: the project-scoped MCP tools, untouched (R-M5).
      # An argument is REFUSED rather than ignored -- the project is already fixed by
      # the caller there, and quietly dropping the filter would let a model believe it
      # narrowed something it did not (the same rule resolve_project_filter states).
      #
      # Without a chat (the MCP call) the token scope alone does not decide it:
      # the code index belongs to the repository, so the asker needs the same
      # repository rights as on the org-wide path (ProjectRepositoryPolicy::Scope,
      # see Scope#code_project_ids). A refusal reads like a missing project, as
      # Mcp::ToolCall answers one. A chat context keeps its own gate (R-M5).
      def self.single_project_code_target(args, context)
        return Result.invalid_input('the project filter applies to org-wide calls only') if args[:project].presence
        return Result.new(error: 'project context missing') if context.project.nil?
        return Result.new(error: 'Project not found or not accessible.', code: :not_found) unless context.chat || code_readable?(context)

        context.project
      end

      def self.code_readable?(context)
        return false if context.actor.nil?

        repositories = ProjectRepository.where(organisation_id: context.project.organisation_id,
                                               project_id: context.project.id)
        Pundit.policy_scope!(context.actor, repositories).exists?
      end
      private_class_method :code_readable?

      # No project with a connected repository is reachable for this asker. An empty
      # SUCCESS, not an error: it is the same statement the five tools already make
      # about an un-indexed project, one level up, and "the search engine is broken"
      # is exactly the conclusion it must not invite.
      def self.no_code_project_result(context)
        Result.new(content: 'No project with a connected code repository is reachable for you.',
                   citations: [], kind: :empty,
                   coverage: context.scope.coverage_with(searched: 0))
      end

      # What a code answer covers: exactly ONE project, always -- vision, capabilities
      # and symbols are per project, so the fraction here reports how much of the
      # organisation has code this asker may reach.
      #
      # Named when the question named it, counted otherwise: the same "named, not
      # counted" rule Scope#coverage_with states, where the counted sentence means
      # "your rights stopped here" and a question that itself named a project must not
      # wear it. A chip is picked up by coverage_with on its own.
      def self.code_coverage(args, context, project)
        return nil unless org_wide?(context)

        context.scope.coverage_with(searched: 1, chosen: (project.name if args[:project].presence))
      end

      # Which project a code answer is about, prefixed to its content on the ORG
      # path. Each of the five code tools answers for exactly one project, and
      # nothing in the payload itself says which: file paths, capability names and a
      # vision text do not carry it, and `coverage` never reaches the model. Without
      # this the model can only guess whose code it just read.
      #
      # nil on the single-project path, so those payloads stay byte-identical
      # (R-M5, and the MCP wire format with them). Sanitized because a project name
      # is user text and two of these tools declare fence_guarded: true, which turns
      # the channel guard off on the way into the prompt.
      def self.with_code_project(context, project, body)
        return body unless org_wide?(context)

        "Project: #{Lalabase::FenceGuard.sanitize(project.name)}\n\n#{body}"
      end

      # The L7 coverage of an org-wide call for `area`, nil on the single-project
      # path — matches Result#coverage's "nil = not applicable".
      # `only_project` is the Project the `project` filter resolved to, or nil.
      def self.coverage_for(context, area:, only_project: nil)
        return nil unless org_wide?(context)
        # S3a T5: a call narrowed to ONE project by the `project` filter must not
        # wear the org-wide reach, or the answer claims to have looked at twelve
        # projects while looking at one. It is NAMED rather than counted for the
        # same reason the chip is: the user asked for this narrowing, and
        # "Durchsucht: 1 von 12" is the sentence that reports a rights limit.
        return context.scope.coverage_with(searched: 1, chosen: only_project.name) if only_project

        context.scope.coverage(area: area)
      end

      # Reach of an MCP call (inbox workflow S1, doc/mcp_inbox_workflow_plan.md §3):
      #   :project — the dispatcher injects a required project_id, the ToolCall
      #              resolves + gates the project and runs under its tenant.
      #   :token   — the call reaches as far as the token: no project gate,
      #              project_id becomes an optional filter and Context#reach carries
      #              the token's organisations and projects. Only the MCP surface
      #              knows tokens, so registry_spec pins :token tools to the :mcp
      #              set; and because no project gate authorized the call, such a
      #              tool declares authorization_mode :record and marks its own
      #              decision, which keeps the D7 tripwire armed.
      def self.scope_mode
        :project
      end

      # True when this call runs with a token's reach (Context#reach set).
      def self.token_wide?(context)
        !context.reach.nil?
      end

      # Whether a token-scoped tool reads the optional `project_id` filter the
      # dispatcher would advertise. Default false, and only a :token tool may say
      # true (registry guard): a tool that does not read the filter must not
      # advertise it, because a silently ignored filter is the wrong answer with
      # a straight face (resolve_project_filter makes the same point).
      def self.project_filter?
        false
      end

      # Authorization contract for the MCP runtime tripwire (D7):
      #   :project — authorized by the PAT project-scope check alone. The MCP
      #              dispatcher resolves + gates the project before execute, so a
      #              project-mode tool needs no further per-record check.
      #   :record  — returns a single record and MUST call authorize!, or, for a list
      #              whose rows pass a policy scope, scoped_by_policy!. The ToolCall
      #              asserts it afterwards and raises loudly if it didn't.
      # Chat-path tools never set Context#authorization, so the mode is irrelevant
      # there — the tripwire is an MCP-only concern.
      def self.authorization_mode
        :project
      end

      # Whether the tool needs an authenticated user in its Context. Declared per
      # tool, enforced ONCE in Runner#run_tool_safely: a tool that declares true
      # never reaches #execute without a Context#actor, so "no actor" becomes an
      # explicit tool error instead of whatever the first Pundit call happens to
      # do with nil. Default false — the code/context tools read only
      # organisation and project.
      #
      # The rule is not a comment: registry_spec asserts that every tool reading
      # context.actor (or declaring authorization_mode :record) declares this.
      def self.requires_actor?
        false
      end

      # Whether the tool performs a write (create/update). The MCP ToolCall (D3)
      # refuses to run a mutating tool for a read-only PAT — granting write is an
      # explicit per-token opt-in. Default false; the curated write tools of the
      # :mcp set override to true (registry_spec pins which). Read tools never
      # mutate, so they ignore the flag.
      def self.mutating?
        false
      end

      # Per-record Pundit authorization for record-mode MCP tools (D2). Mirrors a
      # controller's `authorize` but works from a Tools::Context outside the
      # controller stack (precedent: app/models/smart_folder.rb).
      #
      # Raises Pundit::NotAuthorizedError when the actor may not perform `query`
      # on `record` — the ToolCall maps that to a clean "Not authorized." tool
      # error. On success it marks the Context's authorization recorder (if any),
      # which satisfies the :record-mode tripwire. Returns the record for chaining.
      #
      # @param context [Lalabase::Tools::Context]
      # @param record [Object] the ActiveRecord instance being accessed
      # @param query [Symbol] the policy predicate, e.g. :show?
      def self.authorize!(context, record, query)
        policy = Pundit.policy!(context.actor, record)
        raise Pundit::NotAuthorizedError.new(query: query, record: record, policy: policy) unless policy.public_send(query)

        context.authorization&.record!
        record
      end

      # Marks the decision of a list tool whose rows pass a policy scope instead of a
      # record check: the scope IS the authorization, and an empty list is its answer,
      # not a refusal. Call it before the read, so the D7 tripwire stays armed for a
      # tool that reads without it.
      def self.scoped_by_policy!(context)
        context.authorization&.record!
      end

      # The tickets of `relation` the caller can find: the actor's read rights and,
      # on an MCP call, the reach of its token (Tickets::ReadableForToken owns both;
      # the assistant has no token and is limited by the rights alone). get_ticket,
      # post_comment, create_time_session and update_ticket look their ticket up in
      # here, so a ticket without read access answers exactly like a missing one.
      # One exception: summarize_time_sessions (resolve_ticket) calls the policy
      # scope itself and does not pass through here. A lookup outside the scope
      # followed by authorize! answered "Not authorized." instead, which told a
      # caller with access to the project, but not to its tickets, which ticket
      # numbers exist; numbers count up and can be tried one by one
      # (spec/requests/api/mcp_ticket_existence_spec.rb).
      #
      # authorize! stays after the lookup: it marks the record-mode tripwire and
      # checks the record once more. context.organisation must be set, the rows
      # are bound to it and the rights resolve under it as the tenant.
      def self.readable_tickets(context, relation)
        Tickets::ReadableForToken.call(user: context.actor, organisation: context.organisation,
                                       relation: relation, token: context.token)
      end

      # Resolves the set of ProjectRepository IDs to search for a tool call.
      # Thin adapter over Lalabase::RepoScope — unwraps the per-request Context into
      # the primitives it expects.
      #
      # `project` is the one an org-wide code tool resolved for itself
      # (resolve_code_project); it falls back to the single-project path's project
      # (MCP). The chat's pin travels through either way, and RepoScope INTERSECTS it
      # with that project's repositories rather than trusting it -- see the ⚠️ there.
      # It used to be trusted, on the strength of a Chat validation projekt_chat_abbau
      # removed.
      #
      # @param context [Lalabase::Tools::Context]
      # @param project [Project, nil]
      # @return [Array<String>] ProjectRepository UUIDs
      def self.repo_ids_for(context, project: nil)
        Lalabase::RepoScope.ids_for(
          project: project || context.project,
          organisation: context.organisation,
          pinned_repo_id: context.chat&.project_repository_id
        )
      end
    end
  end
end
