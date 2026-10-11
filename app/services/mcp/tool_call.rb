# frozen_string_literal: true

module Mcp
  # Executes a single MCP tool call: resolves + authorizes the target project from
  # the PAT scope, sets the tenant, builds the Tools::Context and runs the tool,
  # then maps the Tools::Result onto an MCP::Tool::Response.
  #
  # AUTHORIZATION (D7): every project-scoped call goes through #authorized_project
  # — a tool can NOT run without the PAT project-scope check first. For
  # project-mode tools that scope check IS the authorization (mirrors the API's
  # with_project_scope). Record-mode tools (e.g. get_ticket) additionally MUST
  # call Base.authorize! on the single record they return;
  # #verify_record_authorization! asserts they did and raises loudly otherwise —
  # the runtime tripwire, MCP's verify_authorized.
  #
  # TOKEN-SCOPED tools (Base.scope_mode :token, inbox workflow S1): there is no
  # project to gate, so nothing here authorizes the call. The tool receives the
  # token's reach (PersonalAccessToken#reach) through Context#reach, keeps
  # `project_id` as an optional filter argument, runs WITHOUT an ambient tenant
  # (its query names the organisations explicitly) and, being record-mode by
  # registry rule, marks its own authorization decision or the tripwire fires.
  # The read-only gate (D3) and the idempotency replay apply to both modes.
  #
  # A project the token cannot access is reported exactly like a missing one — no
  # existence leak (mirrors Api::TokenAuthenticatable's RecordNotFound-on-scope-miss).
  class ToolCall
    PROJECT_ID_KEY = :project_id
    # Reserved arg the dispatcher injects into mutating tools' schema (D9). Carries
    # the client idempotency key; stripped from the args the tool itself sees.
    IDEMPOTENCY_KEY = :idempotency_key
    # The id argument a write addresses, for the provenance log: a token-scoped
    # write has no project on the seam, so the record it names is the only
    # handle an incident responder gets (D9).
    TARGET_ARG_KEYS = %i[notification_id ticket_id].freeze
    # The `_meta` keys of the machine field (see #result_to_response). Prefixed,
    # as the MCP spec asks of a server's own `_meta` keys.
    KIND_META_KEY = 'lalabase/kind'
    CODE_META_KEY = 'lalabase/code'
    REASON_META_KEY = 'lalabase/reason'

    # Raised when a :record-mode tool returns without authorizing the record it
    # served — a programming error, never a client condition. Propagates out of
    # #response (it is NOT a Pundit::NotAuthorizedError, so the rescue below skips
    # it); the MCP SDK then wraps it as a JSON-RPC internal error (-32603).
    class AuthorizationNotPerformedError < StandardError; end

    def initialize(token:, tool_class:, args:)
      @token = token
      @tool_class = tool_class
      @args = (args || {}).symbolize_keys
    end

    # @return [MCP::Tool::Response]
    def response
      project = nil
      unless token_scoped?
        project_id = @args[PROJECT_ID_KEY]
        return error_response('project_id is required', code: :invalid_input) if project_id.blank?

        project = authorized_project(project_id)
        return error_response('Project not found or not accessible.', code: :not_found) if project.nil?
      end

      # D3 hard gate: a read-only PAT may never run a mutating tool. Checked here,
      # central to the seam, so no individual write tool can forget it.
      return error_response('This token is read-only; writes are not permitted.', code: :read_only) if write_blocked?

      run_tool(project)
    rescue Pundit::NotAuthorizedError
      # Expected per-record denial (D2): the actor may not touch this record.
      # Reported as a clean tool error — never a leak, never a 500.
      log_write_provenance(project, outcome: 'denied') if @tool_class.mutating?
      error_response('Not authorized.', code: :forbidden)
    end

    private

    def token_scoped?
      @tool_class.scope_mode == :token
    end

    # D3: a mutating tool requested by a read-only token is denied. Read tools
    # (mutating? == false) are never blocked, whatever the token's flag.
    def write_blocked?
      @tool_class.mutating? && @token.read_only?
    end

    # Project mode runs under the project's tenant. Token mode (project nil) runs
    # without one: the tool's query filters organisations explicitly, an ambient
    # tenant would only hide one organisation's rows from a multi-org token.
    def run_tool(project)
      return run_in_place(project) if project.nil?

      ActsAsTenant.with_tenant(project.organisation) { run_in_place(project) }
    end

    def run_in_place(project)
      key = idempotency_key
      result = if key && @tool_class.mutating?
                 execute_idempotently(project, key)
               else
                 execute_tool(project)
               end
      result_to_response(result)
    end

    # Runs the tool once: tripwire check + write-provenance log. Returns the Result.
    def execute_tool(project)
      recorder = Lalabase::Tools::AuthorizationRecorder.new
      result = @tool_class.execute(args: tool_args, context: context_for(project, recorder))
      verify_record_authorization!(recorder, result)
      log_write_provenance(project, outcome: write_outcome(result)) if @tool_class.mutating?
      result
    end

    # An :empty result is success? (no error) but performed no write: a probe
    # for a foreign or missing id must not read as a successful write in the
    # audit trail.
    def write_outcome(result)
      return 'failure' unless result.success?

      result.empty? ? 'not_found' : 'success'
    end

    # Idempotent write (D9): a repeated (token, key) replays the first successful
    # response instead of writing again. The Mcp::IdempotencyStore owns the table
    # access + replay/store strategy (see that class for the trade-off rationale);
    # here we just orchestrate replay-or-execute-then-remember.
    def execute_idempotently(project, key)
      store = IdempotencyStore.new(
        token: @token,
        tool_name: @tool_class.tool_name,
        key: key,
        args: @args.except(IDEMPOTENCY_KEY)
      )

      cached = store.replay
      return cached if cached

      result = execute_tool(project)
      # Only a result that actually wrote is pinned to the key: a not-found
      # answer (:empty, success? because it carries no error) performed nothing,
      # and pinning it would replay "No ... found" forever, even once the record
      # became reachable.
      store.remember(result.content) if result.success? && !result.empty?
      result
    end

    def idempotency_key
      @args[IDEMPOTENCY_KEY].to_s.strip.presence
    end

    # Audit/provenance (D9): every write attempt logs PAT id + origin, so an
    # incident responder can attribute a change to a token and path — Current.user
    # alone does not distinguish the web/api/mcp origins. Logged for success,
    # validation failure, not-found and authorization denial alike. A token-scoped
    # write has no project on the seam and logs "-" for both ids; target= names
    # the record the call addressed (TARGET_ARG_KEYS), on both paths.
    def log_write_provenance(project, outcome:)
      Rails.logger.info(
        "[MCP write] origin=mcp tool=#{@tool_class.tool_name} outcome=#{outcome} " \
        "token_id=#{@token.id} user_id=#{@token.user_id} " \
        "org_id=#{project&.organisation_id || '-'} project_id=#{project&.id || '-'} target=#{target_id}"
      )
    end

    # The raw argument is client text and this line is also written when the tool
    # has just refused that text as malformed: only a well-formed UUID reaches the
    # log, anything else (a newline that would forge a second audit line, prose)
    # is replaced by a marker.
    def target_id
      key = TARGET_ARG_KEYS.find { |name| @args[name].present? }
      return '-' unless key

      value = @args[key].to_s
      Lalabase::Uuid.valid?(value) ? value : 'invalid'
    end

    # D7 runtime tripwire. A :record-mode tool that returns a record payload
    # without calling authorize! would silently serve it past per-record
    # authorization — raise instead, so the bug surfaces as -32603, not a leak.
    #
    # Only a successful, non-empty result actually served a record: an error
    # (bad input) or an :empty result (record not found) carries no record data,
    # so there is nothing to authorize and the tripwire stays quiet. `result` is
    # always a Lalabase::Tools::Result (the Tool.execute contract).
    def verify_record_authorization!(recorder, result)
      return unless @tool_class.authorization_mode == :record
      return if recorder.authorized?
      return unless result.success? && !result.empty?

      raise AuthorizationNotPerformedError,
            "#{@tool_class.tool_name} is a :record-mode tool but served a record without calling authorize!"
    end

    # Resolves the project WITHOUT a tenant (the caller doesn't know the org yet),
    # then gates on the PAT scope AND on the owner's access right now: the scope says
    # where the token may go (all_projects opens every project of the organisation),
    # the owner's rights say whether that person may still be there. Checked here, once,
    # like the read-only gate, so a tool that forgets its own check stays closed.
    # Returns nil for "missing", "out of scope" and "no access" alike: none of them leaks.
    def authorized_project(project_id)
      project = ActsAsTenant.without_tenant { Project.find_by(id: project_id) }
      return nil if project.nil?
      return nil unless @token.accessible_project?(project)
      return nil unless owner_may_use?(project)

      project
    end

    def owner_may_use?(project)
      ActsAsTenant.with_tenant(project.organisation) do
        AccessCheck::ProjectAccessService.can_access_project?(@token.user, project)
      end
    end

    def context_for(project, recorder)
      if project.nil?
        Lalabase::Tools::Context.new(
          actor: @token.user, organisation: nil, project: nil, chat: nil,
          authorization: recorder, reach: @token.reach
        )
      else
        Lalabase::Tools::Context.new(
          actor: @token.user, organisation: project.organisation, project: project, chat: nil,
          authorization: recorder
        )
      end
    end

    # The tool's own arguments, minus the MCP-injected selectors: the idempotency
    # key always; the project id only when the seam consumed it as the gate. In
    # token mode it stays, there it is the tool's optional filter.
    def tool_args
      return @args.except(IDEMPOTENCY_KEY) if token_scoped?

      @args.except(PROJECT_ID_KEY, IDEMPOTENCY_KEY)
    end

    # Every answer leaves here, and here it gets its machine field (terminal
    # client plan, S0 c): `lalabase/kind` on a result, `lalabase/code` (and
    # `lalabase/reason` on a refusal) on an error. In `_meta`, the protocol's
    # place for data beside the result: `structuredContent` would be read by
    # some clients INSTEAD of the text. Additive, the text stays as it was.
    # The SDK's own input errors never pass through here; Dispatcher adds theirs.
    def result_to_response(result)
      if result.success?
        MCP::Tool::Response.new([{ type: 'text', text: result.content.to_s }],
                                meta: { KIND_META_KEY => result.kind.to_s })
      else
        error_response(result.error.to_s, code: result.error_code, reason: result.reason)
      end
    end

    def error_response(message, code:, reason: nil)
      meta = { CODE_META_KEY => code.to_s }
      meta[REASON_META_KEY] = reason.to_s if reason.present?
      MCP::Tool::Response.new([{ type: 'text', text: message }], error: true, meta: meta)
    end
  end
end
