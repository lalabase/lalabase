# frozen_string_literal: true

module Lalabase
  module Tools
    # Orchestrates the LLM tool-use loop.
    #
    # Each iteration calls provider.chat(messages:, tools:) and either:
    #   a) gets text back (no tool_calls) → final answer, exit loop
    #   b) gets tool_calls back → execute them, append results, loop again
    #
    # At iteration `max_iterations` we call provider.stream_chat WITHOUT tools
    # so the model is forced to produce a textual answer (no more drill-down).
    # This is gentler than hard-aborting mid-loop and keeps a sensible final
    # message even when the agent would otherwise still want to call tools.
    #
    # Audit trail in @tool_calls_log records every tool invocation (tool,
    # args, duration, success, summary, iteration) for chatposts.tool_calls
    # via the ChatResponseJob integration in M8.3.8.
    #
    # Citations from each successful tool execution are appended to @citations
    # with dedup over (type, id) so we don't double-cite a symbol the baseline
    # retrieval already surfaced.
    #
    # token_usage in the result hash is the SUM across every provider call
    # (each loop iteration's chat() plus the final stream_chat) so the caller
    # can attribute the true cost of a tool-heavy turn, not just the last call.
    class Runner
      DEFAULT_MAX_ITERATIONS = 5

      # Threshold for accumulated tool-result characters in ONE RUN. A call that
      # starts below it still appends its whole result, even if it crosses it.
      #
      # ⚠️ Sized so an ORDINARY answer never meets it. The brake exists for a run
      # that reads the same kind of thing over and over, not for one thorough call,
      # and a limit that fires on normal work would trade a rare blow-up for a
      # frequent thin answer. Measured against the largest single payload the tools
      # can produce short of pathology: RecentActivity at its MAX_LIMIT of 200 rows
      # is roughly 50-70k characters once JSON.pretty_generate has indented it. A
      # budget at the 48_000 ChatResponseJob#cap_history gives the replayed history
      # would have been spent by that one legitimate call.
      #
      # 120_000 is about 30k tokens by the CHARS_PER_TOKEN 4 heuristic the rest of
      # the stack uses. It leaves room for a maximal list call plus several ordinary
      # ones. It stops further tool execution after an oversized result, but is
      # not a hard ceiling on the content already appended.
      DEFAULT_MAX_TOOL_RESULT_CHARS = 120_000

      # Sent to the MODEL as a tool result, so it reads like the other tool errors
      # ('unknown tool: x', 'no authenticated user in this context'): English, short,
      # and it says what to do next rather than only what went wrong.
      BUDGET_EXHAUSTED_ERROR = 'tool result budget exhausted for this answer; ' \
                               'answer with what you have already gathered'

      # `asker` is the author of the question the run answers. It becomes the
      # Context#actor, so every tool runs under the ASKER's rights, not under a
      # chat- or organisation-wide role — the same principal the content retrieval
      # already gates on. Named `asker:` (not `actor:`) on purpose: "Actor" is
      # taken by the command objects under app/services/actors/ (CLAUDE.md, Naming).
      # nil is a legitimate value (empty history); the requires_actor? bar below
      # turns it into a refusal instead of a nil-user policy call.
      def initialize(chat:, provider:, messages:, citations: [], max_iterations: DEFAULT_MAX_ITERATIONS,
                     max_tool_result_chars: DEFAULT_MAX_TOOL_RESULT_CHARS,
                     model: nil, max_tokens: 1500, temperature: 0.7, tool_set: :assistant, asker: nil)
        # M1: max_iterations < 1 would skip the loop body entirely and never
        # offer tools — a misconfiguration, not a valid mode. (max_iterations=1
        # is the explicit "no tool rounds, stream immediately" sentinel.)
        raise ArgumentError, "max_iterations must be >= 1 (got #{max_iterations})" if max_iterations.to_i < 1

        raise ArgumentError, "max_tool_result_chars must be >= 1 (got #{max_tool_result_chars})" if
          max_tool_result_chars.to_i < 1

        @chat            = chat
        @provider        = provider
        @messages        = messages.dup
        @citations       = (citations || []).dup
        @tool_calls_log  = []
        @max_iterations  = max_iterations
        @max_tool_result_chars = max_tool_result_chars.to_i
        @tool_result_chars = 0
        @model           = model
        @max_tokens      = max_tokens
        @temperature     = temperature
        # Which named Registry set this runner may call (D6). Every caller passes its
        # set explicitly; the default exists so a console or a spec does not have to,
        # and it is pinned in runner_spec so it cannot drift.
        @tool_set        = tool_set
        @asker           = asker
        @seen_keys       = Set.new(@citations.map { |c| citation_key(c) })
        # H1: accumulate token usage across EVERY provider call (each loop's
        # chat() + the final stream_chat) so the caller's billing attribution
        # isn't under-reported by the intermediate tool-rounds.
        @usage_total     = Hash.new(0)
        @usage_model     = nil
        @usage_estimated = false
        # S3a T3 (L7): narrowest coverage any successful tool reported, or nil.
        @coverage        = nil
      end

      attr_reader :tool_calls_log, :citations

      # @yield [String] streamed text delta of the FINAL turn
      # @return [Hash] {content:, model_used:, token_usage:, coverage:}
      #
      # CONTRACT: if a provider call raises mid-loop, the exception propagates
      # and #citations / #tool_calls_log hold a PARTIAL loop state. Callers
      # MUST NOT persist those accessors on the exception path (ChatResponseJob
      # routes to its error handler instead).
      def call(&on_chunk)
        raise ArgumentError, 'Runner#call requires a block (on_chunk)' unless block_given?

        iter = 0

        loop do
          iter += 1

          # Final iteration → ask without tools so the model produces a
          # textual answer instead of attempting another drill-down.
          return finalize_streaming(&on_chunk) if iter >= @max_iterations

          response = @provider.chat(
            messages: @messages,
            tools: Registry.all_schemas(set: @tool_set),
            model: @model,
            max_tokens: @max_tokens,
            temperature: @temperature
          )
          accumulate_usage(response[:token_usage])

          # Text-only response → this IS the final answer. Call on_chunk
          # once with the full content so the UI sees a single update,
          # matching what stream_chat would have done for a one-chunk reply.
          if response[:tool_calls].blank?
            on_chunk.call(response[:content]) if response[:content].present?
            return text_result(response)
          end

          @messages << assistant_tool_call_message(response)
          execute_and_append_tool_calls(response[:tool_calls], iter)
        end
      end

      private

      def finalize_streaming(&on_chunk)
        # M4: tell the model it has exhausted its tool budget so it summarises
        # with what it gathered instead of (futilely) wanting more tools. Plan
        # §1: "Bei Erreichen: LLM bekommt 'limit reached'-Hinweis". Appended to
        # the last tool-result rather than as a new user turn, so the Anthropic
        # translator doesn't see two consecutive user turns.
        append_limit_notice

        result = @provider.stream_chat(
          messages: @messages,
          model: @model,
          max_tokens: @max_tokens,
          temperature: @temperature,
          &on_chunk
        )
        accumulate_usage(result[:token_usage])
        {
          content: result[:content],
          model_used: result[:model_used] || @usage_model,
          token_usage: snapshot_usage,
          coverage: @coverage
        }
      end

      def execute_and_append_tool_calls(tool_calls, iter)
        deduped_tool_calls(tool_calls).each do |tool_call|
          start = Time.current
          # ⚠️ The budget is checked BEFORE the call, not after it. Refusing a call
          # once its result is already on @messages is not a budget at all -- the
          # cost is paid the moment the content is appended.
          result = budget_spent? ? budget_refusal(tool_call) : run_tool_safely(tool_call)
          log_call(tool_call, result, iter, start)
          append_tool_result(tool_call[:id], result)
          next unless result.success?

          append_new_citations(result.citations)
          track_coverage(result.coverage)
        end
      end

      # The ONE place a tool result is APPENDED to @messages, so the accounting
      # cannot be bypassed by a future branch that appends its own. (#append_limit_notice
      # grows the LAST result's content afterwards without charging it: it runs once the
      # loop is over, so no call can follow it and spend what it did not pay for.)
      #
      # Charges what was APPENDED, refusals included. One rule, and it is the rule
      # that matters: what lands here is re-sent on every following round and on the
      # final stream_chat, so its cost is multiplied by the rounds still to come.
      def append_tool_result(call_id, result)
        message = tool_result_message(call_id, result)
        @messages << message
        @tool_result_chars += message[:content].to_s.length
      end

      # ⚠️ DEFAULT_MAX_ITERATIONS caps ROUNDS, not calls: every tool_call of one
      # provider response runs inside a single iteration, so ten parallel get_ticket
      # calls all land in one round. Until this budget existed, nothing bounded their
      # total size at all -- #tool_result_message never truncated.
      #
      # The scale that makes it matter: ChatResponseJob#cap_history normally trims
      # replayed history to 48_000 chars (always keeping the newest turn), while
      # ONE Tools::GetTicket call may return
      # 50 posts at MAX_BODY_CHARS 8_000 for body_html AND body_text. A single call
      # could be an order of magnitude larger than the entire history budget.
      #
      # ⚠️ What this does NOT do: bound one result. The call that crosses the line
      # still lands in full. JSON results use JSON.pretty_generate; cutting the
      # string would break JSON. GetTicket's smaller chat full-text allowance only
      # reduces full_text and post_id reads: ordinary comment pages, uncapped
      # metadata and JSON escaping can still exceed this threshold. At most one
      # successful result crosses it; refusal messages and the final limit notice
      # can add further characters. A whole-result boundary is separate work.
      def budget_spent?
        @tool_result_chars >= @max_tool_result_chars
      end

      # Answered as an ordinary failed result, which the loop already knows how to
      # carry: #tool_result_message renders "ERROR: ..." with is_error, #log_call puts
      # it in the audit trail, and the success? guard keeps its (absent) citations and
      # coverage out. A dropped call would be worse than a refused one -- the provider
      # 400s on a tool_call the next request does not answer.
      def budget_refusal(tool_call)
        Rails.logger.warn(
          "Lalabase::Tools::Runner: refusing #{tool_call[:name].inspect} — tool result budget spent " \
          "(#{@tool_result_chars}/#{@max_tool_result_chars} chars)"
        )
        Result.new(error: BUDGET_EXHAUSTED_ERROR)
      end

      # L7 (S3a T3): keep the NARROWEST coverage any successful tool reported.
      # A multi-tool answer wears the most-restricted label — three sums, one of
      # them narrowed, must not read as org-wide. Failed calls carry no coverage
      # worth reporting (their numbers never reached the answer).
      # Form check first: `coverage` is a contract field any tool may set, and this
      # runs OUTSIDE run_tool_safely's rescue — a malformed value must cost the
      # notice, never the answer.
      def track_coverage(coverage)
        return unless well_formed_coverage?(coverage)

        # ⚠️ `outside` survives the comparison, the NUMBERS compete (review of
        # #642). It is not a property of one tool's reach, it is a statement about
        # the whole answer: something the thread points at was read from beyond it
        # (GetTicket.by_id). Carried on a hash it would ride along only when that
        # hash happened to win, and it usually loses -- the retriever counts the
        # projects that actually returned content, SummarizeTimeSessions can report
        # 0. Then the sentence under the answer simply never appears, which is the
        # silent-narrowing failure L7 exists to prevent, one level up.
        outside = @coverage&.[](:outside) || coverage[:outside]
        @coverage = coverage unless @coverage && @coverage[:searched] <= coverage[:searched]
        @coverage = @coverage.merge(outside: true) if outside
      end

      def well_formed_coverage?(coverage)
        coverage.is_a?(Hash) && coverage[:searched].is_a?(Integer) && coverage[:total].is_a?(Integer)
      end

      # M2: an LLM occasionally emits two tool_calls sharing an id. Both
      # OpenAI and Anthropic reject duplicate tool_call_ids on the next
      # round-trip with an opaque 400, so drop the later collisions here
      # (keep first occurrence) and log loudly.
      #
      # R2-4: empty/nil ids are their own collision class — two empty ids
      # would 400 just like two shared ids, so they dedup too (the
      # provider's M1/R2-1 validation should prevent empty ids upstream,
      # but the dedup stays symmetric with the 400-prevention rationale).
      def deduped_tool_calls(tool_calls)
        seen = Set.new
        tool_calls.select do |tc|
          id = tc[:id].to_s
          if seen.include?(id)
            Rails.logger.warn(
              "Lalabase::Tools::Runner: dropping duplicate tool_call id #{id.inspect}"
            )
            next false
          end
          seen << id
          true
        end
      end

      def run_tool_safely(tool_call)
        tool_klass = Registry.by_name(tool_call[:name], set: @tool_set)
        return Result.new(error: "unknown tool: #{tool_call[:name]}") if tool_klass.nil?

        # Fail-closed bar, BEFORE the dispatch: a tool that authorizes against a
        # user must not run without one. Without this the call would reach the
        # tool and it would depend on the individual Pundit policy whether a nil
        # user raises or is quietly accepted — fail-closed by accident, not by
        # contract. One enforcement point, declared per tool (Base#requires_actor?).
        context = build_context
        if tool_klass.requires_actor? && context.actor.nil?
          Rails.logger.warn(
            "Lalabase::Tools::Runner: refusing #{tool_call[:name].inspect} — no actor in context"
          )
          return Result.new(error: 'no authenticated user in this context')
        end

        # Defense in depth: the tool's own execute already normalises non-Hash
        # args, but symbolize_keys on nil would crash before reaching the
        # tool. Belt and suspenders.
        safe_args = (tool_call[:args].is_a?(Hash) ? tool_call[:args] : {}).symbolize_keys

        tool_klass.execute(args: safe_args, context: context)
      rescue StandardError => e
        Rails.logger.error(
          "Lalabase::Tools::Runner: tool #{tool_call[:name].inspect} crashed: #{e.class}: #{e.message}"
        )
        Result.new(error: "tool crashed: #{e.class}")
      end

      def append_new_citations(new_cites)
        # Defensive: a Hash (single citation) would turn into [[k,v],...] under
        # Array(); tools always return Arrays, but guard the contract anyway.
        cites = new_cites.is_a?(Array) ? new_cites : []
        cites.each do |c|
          key = citation_key(c)
          # L1: a citation with neither type nor id collapses to ":" and would
          # dedup all such entries to one. Append it without deduping rather
          # than silently dropping distinct-but-malformed citations.
          if key == ':'
            @citations << c
            next
          end
          if @seen_keys.include?(key)
            # A drill-down may read comments after RAG already cited their ticket.
            # Dedup the displayed source, but retain every comment's access provenance.
            post_ids = c[:post_ids] || c['post_ids']
            if post_ids
              existing = @citations.find { |citation| citation_key(citation) == key }
              existing[:post_ids] = Array(existing.delete('post_ids') || existing[:post_ids]) | post_ids
            end
            next
          end

          @seen_keys << key
          @citations << c
        end
      end

      # Stable key for dedup. Citations from JSON-roundtrips may have string
      # keys; canonical citations from the Retriever/Tools have symbol keys.
      # Normalise to handle both.
      def citation_key(cite)
        type = cite[:type] || cite['type']
        id   = cite[:id]   || cite['id']
        "#{type}:#{id}"
      end

      def log_call(tool_call, result, iter, start)
        @tool_calls_log << {
          tool: tool_call[:name],
          args: tool_call[:args],
          result_summary: result.summary_for_audit,
          succeeded: result.success?,
          duration_ms: ((Time.current - start) * 1000).round,
          iteration: iter
        }
      end

      # `project: nil` since projekt_chat_abbau: a chat has no project any more, so
      # the tools resolve their rows through `scope` alone. The Context keyword stays
      # because MCP still builds one WITH a project (Mcp::ToolCall, its mandatory
      # project_id) -- that is the single-project path this cut deliberately left
      # alone (R-M5).
      def build_context
        Context.new(chat: @chat, organisation: @chat.organisation, project: nil, actor: @asker,
                    scope: org_scope)
      end

      # The org-wide reach (Plan §9.1). Memoized so all tool rounds of one run share
      # the per-area resolution cache.
      def org_scope
        @org_scope ||= Scope.for(chat: @chat, actor: @asker)
      end

      def assistant_tool_call_message(response)
        # Canonical form for the next chat() iteration. content stays nil/blank
        # when the model emitted no text alongside the tool_calls — translators
        # (translate_messages in OpenAI / translate_messages_for_anthropic) know
        # how to wrap this.
        {
          role: 'assistant',
          content: response[:content],
          tool_calls: response[:tool_calls]
        }
      end

      # Tool output on its way INTO the model loop. FenceGuard runs here, at the channel,
      # rather than inside each tool: results carry attacker-fillable text (ticket titles,
      # descriptions, post bodies) and the MCP wire format must stay byte-exact, so the
      # tools' own strings are left alone (see Base.json_result).
      #
      # EXCEPT for a result that declares fence_guarded?. The code tools sanitize the
      # foreign part (a symbol signature) themselves and then wrap it in a Markdown fence
      # ON PURPOSE. Sanitizing here would rewrite exactly those deliberate fences and hand
      # the model ''' where a code block belongs. Default is to guard, so forgetting the
      # declaration costs formatting, never safety.
      def tool_result_message(call_id, result)
        content = if !result.success?
                    "ERROR: #{result.error}"
                  elsif result.fence_guarded?
                    result.content.to_s
                  else
                    Lalabase::FenceGuard.sanitize(result.content)
                  end
        msg = { role: 'tool', tool_call_id: call_id, content: content }
        # Surface tool failure to the Anthropic translator so it can set
        # is_error: true on the wire (helps Claude reason about the failure).
        msg[:is_error] = true unless result.success?
        msg
      end

      def text_result(response)
        {
          content: response[:content],
          model_used: response[:model_used] || @usage_model,
          token_usage: snapshot_usage,
          coverage: @coverage
        }
      end

      # H1: accumulate token usage across every provider call. Numeric fields
      # sum; model is the last seen; estimated is sticky-true (if ANY call
      # estimated, the aggregate is estimated).
      def accumulate_usage(usage)
        return if usage.blank?

        @usage_total[:input_tokens]  += usage[:input_tokens].to_i
        @usage_total[:output_tokens] += usage[:output_tokens].to_i
        @usage_total[:total_tokens]  += usage[:total_tokens].to_i
        @usage_total[:cost_cents]    += usage[:cost_cents].to_f
        @usage_total[:duration_ms]   += usage[:duration_ms].to_i
        @usage_model = usage[:model] if usage[:model].present?
        # sticky-true: aggregate is estimated if ANY call was estimated.
        # (Not memoization — rubocop's MemoizedInstanceVariableName misreads ||=.)
        @usage_estimated = true if usage[:estimated] == true
      end

      def snapshot_usage
        Lalabase::Llm::TokenUsage.build(
          input_tokens: @usage_total[:input_tokens],
          output_tokens: @usage_total[:output_tokens],
          total_tokens: @usage_total[:total_tokens], # summed upstream totals — see TokenUsage.build
          cost_cents: @usage_total[:cost_cents],
          model: @usage_model,
          estimated: @usage_estimated,
          duration_ms: @usage_total[:duration_ms]
        )
      end

      # M4: append the "limit reached" notice to the LAST tool-result content
      # (merge into a fresh hash so we never mutate a message shared with the
      # caller via the shallow dup). Only when tools were actually used and
      # the last message is a tool-result — otherwise there's nothing to
      # append to and no notice is warranted.
      def append_limit_notice
        return if @tool_calls_log.empty?

        last = @messages.last
        return unless last && last[:role].to_s == 'tool'

        @messages[-1] = last.merge(
          content: "#{last[:content]}\n\n[#{limit_notice_text}]"
        )
      end

      # R2-1: render in the chat's PINNED language (M8.2 language-lock), not
      # the request locale — otherwise a German-locked chat under an English
      # request would get an English notice nudging the model's output
      # language. The Runner owns @chat, so it can localise independently of
      # whatever locale the caller happens to be in.
      def limit_notice_text
        I18n.with_locale(@chat.language.presence || I18n.locale) do
          I18n.t(
            'jobs.ai_chat.tool_limit_reached',
            default: 'Tool-call limit reached — answer now using the information gathered so far.'
          )
        end
      end
    end
  end
end
