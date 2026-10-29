# frozen_string_literal: true

module Mcp
  # Durable idempotency for MCP write tools (D9), backed by the
  # mcp_idempotency_keys table. The /api/v1 writes share it (Api::V1::Idempotent,
  # cli_rest_plan D7): one key space per token, so a key used on one surface
  # can never replay an answer on the other (their fingerprints differ). Extracted from Mcp::ToolCall so the ToolCall stays
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
  #
  # WHICH KEY the store can hold is decided here, once, for both surfaces
  # (.client_key, .storable_key?): the REST header and the MCP argument are read
  # and bounded by the same rule, and each surface refuses a key outside it
  # BEFORE the write, in its own envelope (422 invalid_idempotency_key,
  # invalid_input).
  class IdempotencyStore
    MISMATCH_ERROR = 'idempotency_key already used with different parameters'
    # Bytes, not characters. The unique index on (token, key) holds about 2.7 KB,
    # and the key is stored only AFTER the write: a longer key wrote, failed to
    # be stored with an error, and wrote again on every retry.
    MAX_KEY_LENGTH = 255

    # The key a client sent, read the same way on both surfaces: surrounding
    # whitespace dropped (String#strip, which drops a NUL at either end too), and
    # a blank key is no key (nil). Bytes that are no valid UTF-8 come back as
    # sent, for .storable_key? to refuse: String#strip raises on them. A REST
    # header arrives as binary, which is always a valid encoding.
    def self.client_key(raw)
      key = raw.to_s
      return key unless key.valid_encoding?

      key.strip.presence
    end

    # Within the index (bytes) and storable in a PostgreSQL text column: valid
    # UTF-8 without NUL, which the database refuses with an error otherwise.
    # Takes a key from .client_key; a binary one is read as the UTF-8 it claims.
    def self.storable_key?(key)
      utf8 = key.dup.force_encoding(Encoding::UTF_8)
      key.bytesize <= MAX_KEY_LENGTH && utf8.valid_encoding? && !utf8.include?("\0")
    end

    # The refusal of a key outside .storable_key?, naming the field the surface
    # reads it from (the REST header, the MCP argument).
    def self.unstorable_key_message(field)
      "#{field} must be valid UTF-8 without NUL, at most #{MAX_KEY_LENGTH} bytes"
    end

    # @param token [PersonalAccessToken]
    # @param tool_name [String] for the audit column only
    # @param key [String] the client-supplied idempotency key, read by
    #   .client_key and accepted by .storable_key?
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
      record = lookup
      return nil if record.nil?
      return mismatch_result if record == :mismatch

      Lalabase::Tools::Result.new(content: record.response_content)
    end

    # The stored row for this key, :mismatch when the key was used with another
    # request, or nil when it is unseen. The REST surface (Api::V1::Idempotent)
    # replays from here with its own answer shape; #replay is the MCP one.
    def lookup
      record = find
      return nil unless record
      return :mismatch unless record.request_fingerprint == @fingerprint

      record
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
