# frozen_string_literal: true

module Lalabase
  # Neutralises fence openers (``` and ~~~) in text that gets wrapped in a
  # Markdown fenced code block before it reaches the LLM. A signature/snippet
  # containing ``` (or ~~~) would close our fence early and let whatever follows
  # render as Markdown / prompt instructions to the model — a prompt-injection
  # vector once user-edited symbols ever land in indexed content (Layer 1).
  # CommonMark accepts both backtick and tilde fences, so both are neutralised.
  #
  # Single source of truth for the fence guard; PromptBuilder, SearchCodeSymbols
  # and GetSymbolDetails all call into this.
  module FenceGuard
    module_function

    def sanitize(text)
      # .to_s: this is a shared public utility now (not a private per-class
      # helper), so it must not raise on a nil/non-String caller.
      # The first gsub's replacement ("''' ") contains no fence chars, so the
      # second gsub cannot re-trigger on it.
      text.to_s.gsub('```', "''' ").gsub('~~~', "''' ")
    end
  end
end
