# frozen_string_literal: true

module Lalabase
  module Tools
    # Return value of every Tool.execute call.
    #
    # The kind / empty? / summary_for_audit machinery is consumed by
    # Tools::Runner (landing in M8.3.7), which persists the summary into
    # chatposts.tool_calls. Until the Runner ships these methods have no
    # downstream consumer in production — they're specified here so the
    # Runner can plug in without re-litigating the audit-trail shape.
    #
    # Either successful (error: nil, content + optional citations) or failed
    # (error: String, content/citations may be unset).
    # Set of acceptable explicit kind values. Defined outside the Struct.new
    # do-block because Ruby's Struct.new(do...end) defines constants in the
    # ENCLOSING scope, not on the Struct class itself (verified: `S = Struct.new
    # { C = 1 }; S::C` raises NameError).
    # `fence_guarded` is the tool's declaration that its content is ALREADY safe to
    # embed in the prompt: it sanitized the foreign parts itself and then built its own
    # Markdown (the code tools fence a signature on purpose). Runner#tool_result_message
    # guards everything else on the way into the model loop, so the default — false —
    # is the safe direction: a tool that forgets gets sanitized, only an explicit opt-out
    # skips it. Guard-spec: a tool declaring true must call FenceGuard in its own source.
    # `coverage` (S3a T3, L7 — pulled forward from the S3b contract, Plan §9a): an
    # org-wide tool reports how far its answer reaches as {searched:, total:}
    # (projects). nil = not applicable (single-project call, MCP). A CONTRACT
    # field, not a per-tool convention: the narrowing notice under the answer is
    # rendered deterministically from these numbers, never from the model's prose.
    # `code` and `reason` classify an ERROR for a machine reader (terminal client
    # plan, S0 c). Mcp::ToolCall puts them into the answer's `_meta`, so an MCP
    # client tells "bad input" from "refused" without parsing the prose. An error
    # without a code is :refused: the plan's rule for an unknown error is that a
    # client shows it and never retries it. `reason` names the refusal (e.g.
    # :archived) and is free text for a reader, not a closed list.
    Result = Struct.new(:content, :citations, :error, :kind, :fence_guarded, :coverage, :code, :reason,
                        keyword_init: true) do
      def self.invalid_input(message)
        new(error: message, code: :invalid_input)
      end

      def self.refused(message, reason:)
        new(error: message, code: :refused, reason: reason)
      end

      def fence_guarded?
        self[:fence_guarded] == true
      end

      def success?
        # Treat empty / blank error strings as no-error. A defensive caller
        # writing `Result.new(error: msg || '')` should NOT poison the audit
        # trail with "ERROR: " rows. Only a meaningful error string counts.
        error.blank?
      end

      # Derived kind. Invariants:
      # 1. An error result is ALWAYS :error regardless of any explicit kind a
      #    caller passed in (so success? / kind / summary_for_audit cannot
      #    disagree — e.g. Result.new(error: 'x', kind: :ok) still reports
      #    :error and "ERROR: x" in the audit).
      # 2. Unknown kinds (typos like :emty) fall back to :ok with a warning
      #    log so the drift is visible in production telemetry.
      def kind
        return :error if error.present?

        explicit = self[:kind]
        return :ok if explicit.nil?
        return explicit if Result::VALID_KINDS.include?(explicit)

        Rails.logger.warn(
          "Lalabase::Tools::Result: unknown kind #{explicit.inspect}, defaulting to :ok"
        )
        :ok
      end

      def empty?
        kind == :empty
      end

      # The machine class of an error, nil for a success. Same typo guard as #kind:
      # an unknown code is logged and read as the safe default.
      def error_code
        return nil if success?

        explicit = self[:code]
        return :refused if explicit.nil?
        return explicit if Result::ERROR_CODES.include?(explicit)

        Rails.logger.warn("Lalabase::Tools::Result: unknown code #{explicit.inspect}, defaulting to :refused")
        :refused
      end

      def summary_for_audit
        case kind
        when :error then "ERROR: #{error}"
        when :empty then "NO MATCH: #{content.to_s[0, 60]}"
        else
          content.is_a?(String) ? content[0, 100] : "data (#{Array(citations).size} citations)"
        end
      end
    end

    Result::VALID_KINDS = %i[ok empty error].freeze
    # The error classes an MCP client sees (Mcp::ToolCall). :not_found is the
    # same answer for "missing" and "not yours", so it leaks no existence.
    Result::ERROR_CODES = %i[invalid_input read_only not_found forbidden refused].freeze
  end
end
