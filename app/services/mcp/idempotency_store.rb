# frozen_string_literal: true

module Mcp
  # Durable idempotency for MCP write tools (D9), backed by the
  # mcp_idempotency_keys table. Extracted from Mcp::ToolCall so the ToolCall stays
  # focused on "run one tool call safely" and this concern can be unit-tested on
  # its own (no HTTP/dispatcher needed).
  #
  # Usage (the ToolCall owns the orchestration):
  #   store  = IdempotencyStore.new(token:, tool_name:, key:, args:)
  #   cached = store.replay         # a Result to return as-is, or nil
  #   return cached if cached
  #   result = run_the_write
  #   store.remember(result.content) if result.success?
  #
  # STRATEGY — execute-then-store (NOT claim-first). The ToolCall asks #replay
  # first; on a miss it executes the write and then calls #remember. We chose this
  # over claiming the key BEFORE executing because:
  #   - The case we must handle is a SEQUENTIAL client retry (Claude Code retries
  #     after a timeout/error, not concurrently). #replay catches that cleanly:
  #     the first call has already stored its response.
  #   - Claim-first risks a permanently "pending" row if the process dies between
  #     the write committing and the response being recorded — a worse failure mode.
  # ACCEPTED TRADE-OFF: two TRULY simultaneous calls with the same key can both
  # execute before either stores (a rare double-write for a single MCP client).
  # #remember swallows the unique-violation in that race rather than erroring.
  #
  # Keys are scoped per PAT (token + key is the unique constraint), so they cannot
  # collide or leak across tokens.
  class IdempotencyStore
    MISMATCH_ERROR = 'idempotency_key already used with different parameters'

    # @param token [PersonalAccessToken]
    # @param tool_name [String] for the audit column only
    # @param key [String] the client-supplied idempotency key
    # @param args [Hash] the request args the key dedupes (already minus the key);
    #   its fingerprint detects a key reused with a DIFFERENT payload.
    def initialize(token:, tool_name:, key:, args:)
      @token = token
      @tool_name = tool_name
      @key = key
      @fingerprint = self.class.fingerprint(args)
    end

    # Order-stable hash of the request. Only the TOP-LEVEL key order is canonical
    # (sort.to_h) — sufficient because a retrying client resends the same structure;
    # we are detecting accidental reuse of a key, not defending against an adversary.
    def self.fingerprint(args)
      Digest::SHA256.hexdigest(args.sort.to_h.to_json)
    end

    # @return [Lalabase::Tools::Result, nil] a Result to return verbatim (the
    #   stored response, or a mismatch error), or nil when the key is unseen and
    #   the caller should execute the write.
    def replay
      record = find
      return nil unless record
      return mismatch_result unless record.request_fingerprint == @fingerprint

      Lalabase::Tools::Result.new(content: record.response_content)
    end

    # Records a successful write's response so a later retry replays it.
    # requires_new: a duplicate INSERT rolls back only its savepoint, never the
    # caller's transaction (and stays clean under transactional test fixtures).
    def remember(response_content)
      McpIdempotencyKey.transaction(requires_new: true) do
        McpIdempotencyKey.create!(
          personal_access_token_id: @token.id,
          idempotency_key: @key,
          tool_name: @tool_name,
          request_fingerprint: @fingerprint,
          response_content: response_content.to_s
        )
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # The key is already recorded, so ours is an accepted no-op. It surfaces two
      # ways, both expected: the model's uniqueness validation (RecordInvalid) when
      # the row is already visible, or the DB unique constraint (RecordNotUnique)
      # when a concurrent request commits between our validation and our INSERT.
      # Re-raise any OTHER validation failure so a genuine bug stays loud.
      # of_kind? matches on attribute + error type only (added? would also demand
      # the same options, which the uniqueness error carries and we don't pass).
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:idempotency_key, :taken)

      nil
    end

    private

    def find
      McpIdempotencyKey.find_by(personal_access_token_id: @token.id, idempotency_key: @key)
    end

    def mismatch_result
      Lalabase::Tools::Result.invalid_input(MISMATCH_ERROR)
    end
  end
end
