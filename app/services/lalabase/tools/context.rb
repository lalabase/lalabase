# frozen_string_literal: true

module Lalabase
  module Tools
    # Per-request context handed to every Tool.execute call. Built once per call
    # from one of two callers — tools never reach back to global state:
    #   - chat: Tools::Runner builds it from the active Chat, with `actor` set to
    #           the ASKER (author of the question); chat carries the pinned repo.
    #           The asker can be nil on an empty history — the Runner's
    #           requires_actor? bar refuses actor-dependent tools in that case.
    #   - mcp:  the MCP dispatcher builds it from a Personal Access Token, with
    #           `actor` set explicitly and `chat` nil (no chat over MCP).
    # `actor` is the authenticated user; record-mode tools authorize against it.
    # It is NEVER read from Current.user — both callers pass it explicitly.
    # `chat` stays optional — the read tools only read organisation/project, and
    # Base#repo_ids_for reads `chat&.project_repository_id` nil-safe.
    # `authorization` is an optional AuthorizationRecorder, set only by the MCP
    # ToolCall: Base.authorize! marks it, and the ToolCall's D7 tripwire asserts a
    # record-mode tool actually called it. nil on the chat path (no tripwire there).
    # `scope` (S3a T3, Plan §9.1) is the org-wide reach of an ORG THREAD's tool
    # call (a Tools::Scope). Additive on purpose (R-M5): `project` stays the
    # single-project path, which since projekt_chat_abbau only MCP still takes.
    # `reach` (inbox workflow S1, doc/mcp_inbox_workflow_plan.md §3) is the
    # TOKEN-wide reach of an MCP call (a PersonalAccessToken::Reach), set by the
    # ToolCall for a scope_mode :token tool, with `organisation` nil as well.
    #
    # Three reaches: `project` (one project), `scope` (one organisation, an org
    # thread), `reach` (a token's organisations). `project` next to `scope` is
    # the pinned single-project path (Base.org_wide? needs project nil, see
    # list_tickets_spec), but `reach` is EXCLUSIVE: a token-wide call with a
    # project or scope set would let a tool branch on the wrong reach, so the
    # constructor refuses it right here, not three frames into the tool.
    Context = Struct.new(:chat, :organisation, :project, :actor, :authorization, :scope, :reach,
                         keyword_init: true) do
      def initialize(**)
        super
        return if reach.nil?

        other = %i[project scope].reject { |name| self[name].nil? }
        raise ArgumentError, "Context#reach excludes project/scope, got reach+#{other.join('+')}" if other.any?
      end
    end
  end
end
