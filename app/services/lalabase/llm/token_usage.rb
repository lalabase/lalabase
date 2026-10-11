# frozen_string_literal: true

module Lalabase
  module Llm
    # Canonical token-usage hash. ONE source for the shape + the derived bits
    # (total_tokens = input + output, cost rounded to 4 dp) so the two providers
    # AND the Runner's aggregate can't drift apart — the "EXACT key set" contract
    # specs assert this shape, and adding a key (e.g. cached_tokens) should touch
    # one place, not three builders.
    #
    # Providers compute their own cost_cents (provider-specific pricing) and pass
    # it in; the Runner passes the summed cost. duration_ms is per-call for a
    # provider, summed for the Runner — both just flow through.
    #
    # total_tokens defaults to input+output (what a provider reports per call),
    # but the Runner passes its SUMMED total explicitly: it aggregates already-
    # built usages and must trust their reported totals, not re-derive from the
    # summed input/output (which an upstream/test usage may not match exactly).
    module TokenUsage
      module_function

      # -- canonical usage shape; named kwargs
      # are clearer than an options hash (same call style as JobSupport#record_index_run).
      def build(input_tokens:, output_tokens:, cost_cents:, model:, estimated:, duration_ms: nil, total_tokens: nil)
        {
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: total_tokens || (input_tokens + output_tokens),
          cost_cents: cost_cents.round(4),
          model: model,
          estimated: estimated,
          duration_ms: duration_ms
        }
      end
    end
  end
end
