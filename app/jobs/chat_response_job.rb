# frozen_string_literal: true

# Streams an LLM response for the user message bound when the job was enqueued.
#
# Replaces the legacy OpenaiResponseJob. Provider-agnostic via Lalabase::Llm::Factory.
# Builds a *structured* messages array from chatposts (no more "user: x\nassistant: y"
# string-mush), which is the prerequisite for tool-calling in M5+.
class ChatResponseJob < ApplicationJob
  RevisionContextTooLarge = Class.new(StandardError)

  MAX_TOKENS  = 1500
  TEMPERATURE = 0.7

  # Context cap (D15): the replayed conversation history is trimmed to at most this
  # many tokens (oldest turns dropped first) before the call. The system prompt +
  # RAG context are separate (bounded by retrieval); this keeps the FLAT per-message
  # credit price honest for our purchase costs and bounds latency on long chats.
  MAX_CONTEXT_TOKENS      = 12_000
  CONTEXT_CHARS_PER_TOKEN = 4

  # S4-T2 (§7.3): the reference hint carries a ticket TITLE, and a title is
  # unshaped user text (`tickets.title` is validated for presence only). Long
  # enough for a whole prompt, and free to contain quotes and newlines. One
  # line, bounded, same spirit as Tools::GetTicket::MAX_BODY_CHARS.
  MAX_REFERENCE_TITLE_CHARS = 120

  # The project NAME next to it is user text as well since the ASCII whitelist
  # went: one line by normalisation, but up to Project::NAME_MAX_LENGTH long and
  # free to carry quotes or a sentence. So it gets the same treatment at both
  # places it enters the prompt, the scope hint and the reference line. A name
  # is shorter than a title by nature; the number is this surface's own.
  MAX_PROMPT_PROJECT_NAME_CHARS = 80

  queue_as :default
  # Regenerations share a row; serialize streaming writers with the existing
  # Solid Queue semaphore so content and completion metadata cannot interleave.
  limits_concurrency to: 1, key: ->(chat, **) { chat.id }, duration: 30.minutes, on_conflict: :block

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "ChatResponseJob: Record not found - #{error.message}"
  end

  # regenerate_chatpost_id drives the per-answer regenerate: re-stream INTO an
  # existing assistant bubble instead of appending a new turn. nil on the normal
  # answer path.
  #
  # acting_user_id (v1.5): the user who triggered this answer — set server-side
  # from current_user in the controller (never from params). Resolves the
  # persistent per-user style level (technicality/length). nil on already-enqueued
  # pre-v1.5 jobs and any non-user trigger → the neutral 2/2 default applies.
  #
  # style: is gone (2026-08-26). It carried the one-off "shorter/simpler" nudge
  # until 2026-07-19 and was kept one release so queued jobs would not die on
  # retry; that grace period ended 2026-08-19. A serialised job still carrying it
  # now fails with ArgumentError, which is the intended end of the road.
  # Deploy prerequisite #813 to all workers before this release starts sending
  # question IDs. Keep that compatibility release as the minimum rollback target.
  def perform(chat, regenerate_chatpost_id: nil, acting_user_id: nil, question_chatpost_id: nil)
    Rails.logger.debug "ChatResponseJob: Starting processing for chat #{chat.id} (queued question #{question_chatpost_id || 'legacy'})"

    ActsAsTenant.with_tenant(chat.organisation) do
      reloaded_chat = Chat.find(chat.id)
      target = regenerate_chatpost_id && reloaded_chat.chatposts.find_by(id: regenerate_chatpost_id)
      return if regenerate_chatpost_id && !target

      question_id = question_chatpost_id || target&.analysis_context&.fetch('question_id', nil)
      question = question_id ? reloaded_chat.chatposts.not_assistant.find_by(id: question_id) : last_non_assistant_post(reloaded_chat, before: target&.created_at)
      return if question&.meeting_ticket_suggestion_run

      unless question
        update_or_create_error(reloaded_chat, nil, I18n.t('assistant_analysis.revision_unavailable', locale: chat_locale(reloaded_chat))) if target
        return
      end

      acting_user = acting_user_id && User.find_by(id: acting_user_id)
      respond(reloaded_chat, target: target, acting_user: acting_user, question: question)
    end
  end

  private

  # target: when present, an existing assistant chatpost to regenerate in place
  # (reset + re-stream) rather than appending a new one. The style it comes back
  # in is the acting user's stored level, resolved in #style_directives.
  def respond(chat, target: nil, acting_user: nil, question: nil)
    detect_and_lock_language(chat)
    # Every job stops history at its own question, including jobs waiting behind
    # another stream. Later questions and answers must not become its final turn.
    cutoff = question ? question.created_at + Rational(1, 1_000_000) : target&.created_at
    # asker (Content-RAG + a1, this branch): author of the question — gates the content layer and
    # drives the live stream. acting_user (v1.5, main): who triggered the answer — resolves the
    # persistent style preference. Different concepts (often the same user), both needed.
    asker = asker_for(chat, before: cutoff)
    @analysis_revision_answer = Assistant::AnalysisRevision.call(chat: chat, user: asker, context: question&.analysis_context)
    return update_or_create_error(chat, nil, I18n.t('assistant_analysis.revision_unavailable', locale: chat_locale(chat))) if question&.analysis_context&.dig('revision_answer_id').present? && !@analysis_revision_answer

    # Keep the previous source numbering for revisions. Fresh semantic retrieval
    # could assign [1] to a different object; tools remain available for additions.
    rag_result = retrieve_rag_context(chat, before: cutoff, asker: asker) unless @analysis_revision_answer
    messages = build_messages(chat, rag_result, before: cutoff, acting_user: acting_user)
    @analysis_question = @analysis_history.reverse.find { |post| !post.assistant? }
    initial_citations = if @analysis_revision_answer
                          @analysis_revision_answer.source_citations.map(&:symbolize_keys)
                        else
                          (rag_result ? rag_result.citations : [])
                        end
    # Regenerate is destructive-before-call: reset_for_regeneration blanks the
    # bubble so streaming accumulates fresh + the pills hide. Snapshot the prior
    # answer FIRST so a failed re-generation (provider down / rate limit) restores
    # it instead of overwriting a good answer with an error — the pills (gated on
    # model_used) would otherwise never return. nil on the normal path, so the
    # error helpers below behave exactly as before there.
    @regenerate_restore = target && answer_snapshot(target)
    message = target ? reset_for_regeneration(target, initial_citations) : create_assistant_placeholder(chat, initial_citations)
    # a1 (Plan §6): the asker drives the gated live stream. Set AFTER the placeholder is
    # created — its first broadcast goes to the shared stream as a redacted placeholder;
    # the delta writes below then stream un-redacted to the asker's OWN stream, while the
    # others get a single page-refresh at completion (see Chatpost#broadcast_updated).
    message.streaming_asker = asker

    provider = resolve_provider(chat.organisation)
    return mark_service_unavailable(message, chat) if provider.nil?

    generate_answer(chat, message, provider, messages, initial_citations,
                    acting_user: acting_user, asker: asker, rag_coverage: rag_result&.coverage)
  rescue RevisionContextTooLarge
    update_or_create_error(chat, nil, I18n.t('assistant_analysis.revision_too_long', locale: chat_locale(chat)))
  # AiDisabledError inherits from Provider::Error, so this rescue must come
  # before the broad one below — otherwise the GDPR opt-in gate would surface
  # as a generic API error instead of its own explanatory copy.
  rescue Lalabase::Llm::AiDisabledError => e
    Rails.logger.info "ChatResponseJob: AI disabled for organisation: #{e.message}"
    update_or_create_error(chat, message, I18n.t('shared.ai.disabled_member_hint', locale: chat_locale(chat)))
  # Quota exhausted (S3): a SPECIFIC rescue before the broad Provider::Error one, so
  # the member sees the "kontingent aufgebraucht" copy (with the 3-way banner in the
  # settings) instead of a generic API error. Ordered after AiDisabled (opt-in wins).
  rescue Lalabase::Llm::QuotaExceededError => e
    Rails.logger.info "ChatResponseJob: AI quota exhausted: #{e.message}"
    update_or_create_error(chat, message, I18n.t('shared.ai.quota_exhausted_member_hint', locale: chat_locale(chat)))
  rescue Lalabase::Llm::Provider::AuthError => e
    Rails.logger.error "ChatResponseJob: provider unauthorized: #{e.message}"
    update_or_create_error(chat, message, I18n.t('jobs.ai_chat.unauthorized', locale: chat_locale(chat)))
  rescue Lalabase::Llm::Provider::RateLimitError => e
    Rails.logger.error "ChatResponseJob: rate limited: #{e.message}"
    update_or_create_error(chat, message, I18n.t('jobs.ai_chat.api_error', locale: chat_locale(chat)))
  # The provider refused the request (exhausted balance, inaccessible model, rejected
  # parameter). Ahead of the broad Provider::Error arm because "try again later" is
  # the one piece of advice that is certainly wrong here: nothing changes by waiting.
  rescue Lalabase::Llm::Provider::RequestRefusedError => e
    Rails.logger.error "ChatResponseJob: provider refused the request: #{e.message}"
    update_or_create_error(chat, message, refused_copy(chat))
  rescue Lalabase::Llm::Provider::Error => e
    Rails.logger.error "ChatResponseJob: provider error: #{e.message}"
    update_or_create_error(chat, message, I18n.t('jobs.ai_chat.api_error', locale: chat_locale(chat)))
  rescue StandardError => e
    Rails.logger.error "ChatResponseJob: unexpected error: #{e.message}\n#{e.backtrace&.join("\n")}"
    # The class/message are logged above; the user-facing copy stays clean and
    # provider-neutral — no internal exception details leak into the chat.
    update_or_create_error(chat, message, I18n.t('jobs.ai_chat.generic_error', locale: chat_locale(chat)))
  end

  # Which copy a refused request gets. The ONE thing that decides it is whose access
  # was refused, asked of the factory that resolved it (Factory#own_chat_access?) —
  # never re-derived here.
  #
  # Two reasons the BYOK text may exist at all, and both have to hold:
  #   * The organisation owns the account, so it is the only party that CAN act. On a
  #     system credential the same failure is the operator's to fix and the member can
  #     do nothing with the information.
  #   * It says nothing about the operator's billing state. "credit balance too low"
  #     on a shared credential would put our prepaid balance into every customer's
  #     chat, which is why the provider's own words stay in the log either way.
  #
  # NO admin variant, unlike shared.ai.disabled_*_hint: this text is persisted as a
  # chatpost and read by everyone in the project, so there is no reader to tailor it
  # to. It has to be safe for the member and useful for the admin at the same time.
  def refused_copy(chat)
    key = Lalabase::Llm::Factory.own_chat_access?(chat.organisation) ? 'own_access_refused' : 'api_error'
    I18n.t("jobs.ai_chat.#{key}", locale: chat_locale(chat))
  end

  # Creates the empty assistant bubble that deltas stream into. Seeded with the
  # RAG citations so the bubble shows its sources even before the first token.
  def create_assistant_placeholder(chat, initial_citations)
    chat.chatposts.create!(
      organisation: chat.organisation,
      role: :assistant,
      content: '',
      source_citations: initial_citations
    )
  end

  # Regenerate (Plan §9): reuse the existing assistant bubble as the streaming
  # target instead of appending a new turn. Clearing model_used + token_usage
  # flips MessageComponent#answer_complete? back to false, so the per-answer
  # pills disappear during regeneration (the after_update_commit broadcast
  # re-renders the now-empty bubble for every viewer); they reappear when the
  # folded final write lands again. build_messages excludes this blank assistant
  # row, so the model never sees the old answer it is replacing.
  #
  # This runs BEFORE the LLM call, so respond() snapshots the prior answer first
  # (@regenerate_restore) and restores it if the call fails — see answer_snapshot
  # / restore_regenerated_answer. The six fields cleared here mirror the snapshot.
  # source_coverage resets too: the re-run recomputes its reach, and a stale
  # narrowing label under a fresh answer would be exactly the lie L7 forbids.
  def reset_for_regeneration(target, initial_citations)
    target.update!(
      content: '',
      source_citations: initial_citations,
      tool_calls: [],
      source_coverage: nil,
      model_used: nil,
      token_usage: {},
      analysis_context: nil
    )
    target
  end

  # The user-visible state of an assistant answer, captured before a regenerate
  # blanks it, so a failed re-generation can put it back. Mirrors the six fields
  # reset_for_regeneration clears.
  def answer_snapshot(target)
    {
      content: target.content,
      source_citations: target.source_citations,
      tool_calls: target.tool_calls,
      source_coverage: target.source_coverage,
      analysis_context: target.analysis_context,
      model_used: target.model_used,
      token_usage: target.token_usage
    }
  end

  # Put the pre-regeneration answer back (incl. model_used → pills return).
  # Silent by design: a failed "make it shorter" just leaves the original answer
  # standing — v1 has no in-chat way to signal the failed attempt (a toast would
  # be v1.5). Strictly better than replacing a good answer with an error string.
  def restore_regenerated_answer(message)
    message.update!(@regenerate_restore)
  end

  # No usable provider (missing/disabled key). Clear citations + tool_calls — the
  # assistant never used them. Mirrors the exception path in update_or_create_error.
  def mark_service_unavailable(message, chat)
    # Regenerate: restore the original answer instead of clobbering it with the
    # "unavailable" copy (see respond's snapshot note).
    return restore_regenerated_answer(message) if @regenerate_restore

    update_or_create_error(chat, message, I18n.t('jobs.ai_chat.service_unavailable', locale: chat_locale(chat)))
  end

  # Runs the M8.3.8 tool-use loop and folds its result into the bubble. The
  # Runner orchestrates chat-with-tools → execute → loop → streamed final; it
  # streams ONLY the final turn's deltas through the block, so intermediate
  # tool-rounds emit nothing and the bubble stays empty until the assistant
  # actually answers.
  # rag_coverage (S3a T3, L7): the content retrieval's reach on an org thread, or
  # nil. Merged with the tool rounds' coverage below, narrowest wins.
  def generate_answer(chat, message, provider, messages, initial_citations, acting_user: nil, asker: nil,
                      rag_coverage: nil)
    runner = Lalabase::Tools::Runner.new(
      chat: chat,
      provider: provider,
      messages: messages,
      citations: initial_citations,
      # nil, NOT the org's preferred_chat_model. Two reasons, both measured:
      #
      # The provider does `model ||= default_chat_model`, so any non-nil value here wins
      # over what Lalabase::Llm::Factory resolved. Since S7 gave preferred_chat_model its
      # first UI, that is a customer-editable field naming the model that runs on the
      # OPERATOR's key — the same door the factory closed one layer down (the branch that
      # reads the column now lives in the BYOK path only).
      #
      # It also overrode the rung's effective_chat_model, which §6.1 of
      # doc/ki_pakete_plan.md rules out: a package tier decides which model its
      # jurisdiction runs, not a column the customer types into.
      #
      # nil hands the decision back to the factory, which already knows the BYOK case.
      model: nil,
      max_tokens: MAX_TOKENS,
      temperature: TEMPERATURE,
      # The assistant resolves its rows through Context#scope (S3a T3).
      max_iterations: Lalabase::Tools::Runner::DEFAULT_MAX_ITERATIONS,
      # Name the tool set (D6) explicitly. The Runner's own default is pinned to
      # :assistant, but a caller that says which set it wants cannot be surprised
      # by a change to that default.
      tool_set: runner_tool_set(chat),
      # The tools run under the ASKER's rights, the same principal the content
      # retrieval is gated on. nil (empty history) is fail-closed in the Runner:
      # a tool declaring requires_actor? is refused before it touches data.
      asker: asker
    )

    # The gate must close BEFORE the first token leaves. Chatpost#gated_streaming?
    # reads source_citations, which so far holds only the retrieval's citations — a
    # turn whose content came from a TOOL (ticket rows) would look content-free and
    # broadcast live to every reader of the shared chat, whatever their own rights.
    # The tool rounds are finished by the time the first delta arrives, so folding
    # the runner's citations in here is both correct and early enough. Once only:
    # the deltas are the hot path.
    citations_synced = false
    result = runner.call do |delta|
      unless citations_synced
        citations_synced = true
        message.source_citations = runner.citations
      end
      message.update!(content: message.content + delta)
    end

    # Source attribution (Plan §6.2): parse the model's closing [[used_sources: …]]
    # marker off the streamed content, then in the folded write below persist the
    # STRIPPED content (an un-stripped marker would replay as history via
    # build_messages and coax the model into imitating the format) and flag which
    # sources it actually used. No/broken marker → all sources flagged used (lossless
    # fallback = today's behaviour) + a log line for the in-prod follow rate.
    begin
      attribution = Lalabase::ProjectRag::SourceAttribution.parse(message.content)
      log_source_attribution(chat, attribution, initial_citations.size)
      flagged_citations = Lalabase::ProjectRag::SourceNumbering.apply_used_flags(
        citations: runner.citations, initial_count: initial_citations.size, parse_result: attribution
      )
    rescue StandardError => e
      # Attribution is pure string/array work; if it ever raises it must not cost
      # the finished answer (the outer rescue would replace it with an error
      # bubble). Fall back to the unflagged list — all sources stay visible.
      Rails.logger.error "Source attribution failed, falling back to unflagged: #{e.class}: #{e.message}"
      flagged_citations = runner.citations
    end

    # M8.3.8 (perf): ONE final write folds content + citations + tool_calls + usage so
    # the bubble re-renders once, not three times, on the hot path of every answer.
    # source_coverage (S3a T3, L7): the narrowest reach of everything that fed
    # the answer — the deterministic source of the "durchsucht: 3 von 12
    # Projekten" notice.
    usage = result[:token_usage] || {}
    analysis_context = Assistant::AnalysisContext.call(question: @analysis_question,
                                                       history: @analysis_history || [], citations: flagged_citations.map(&:stringify_keys),
                                                       reference_citations: @analysis_reference_sources || [], tool_calls: runner.tool_calls_log.map(&:deep_stringify_keys), revision: @analysis_revision_answer)
    # A revision may use only the preceding answer, without another tool call. Keep
    # its source numbering and scope caveat with that revised text.
    inherited_answer = @analysis_revision_answer if flagged_citations.empty?
    flagged_citations = inherited_answer.source_citations if inherited_answer
    message.update!(
      content: Lalabase::ProjectRag::SourceAttribution.strip(message.content),
      source_citations: flagged_citations,
      tool_calls: runner.tool_calls_log,
      source_coverage: narrowest_coverage(rag_coverage, result[:coverage], @analysis_revision_answer&.source_coverage&.symbolize_keys) || inherited_answer&.source_coverage,
      model_used: result[:model_used],
      analysis_context: analysis_context,
      token_usage: usage.transform_keys(&:to_s)
    )
    track_ai_usage(chat.organisation, provider, result, chat: chat, acting_user: acting_user)
  end

  # L7: an answer wears the NARROWEST reach of what fed it — the content
  # retrieval and the tool rounds alike, the same rule Runner#track_coverage
  # applies between tools. nil when nothing reported a reach.
  def narrowest_coverage(*coverages)
    present = coverages.compact
    narrowest = present.min_by { |coverage| coverage[:searched] }
    # ⚠️ Same rule as Runner#track_coverage, and for the same reason (review of
    # #642): the numbers compete, `outside` is OR-ed. The retrieval coverage counts
    # only the projects that actually returned content, so it is usually the
    # narrower one and it never sets the flag -- min_by would hand back the hash
    # without it and the sentence under the answer would be gone.
    return narrowest if narrowest.nil? || present.none? { |coverage| coverage[:outside] }

    narrowest.merge(outside: true)
  end

  # Observability for the marker follow rate in production (Plan §6.2). info-level:
  # a missing marker is an expected, lossless fallback (all sources shown), not an error.
  def log_source_attribution(chat, attribution, numbered_count)
    Rails.logger.info(
      "ChatResponseJob: source attribution chat=#{chat.id} " \
      "marker_found=#{attribution[:marker_found]} used=#{attribution[:used_indices].inspect} " \
      "numbered=#{numbered_count}"
    )
  end

  # Builds the structured messages array directly from chatposts.
  # Includes the system prompt as the first entry. Excludes the empty assistant
  # placeholder we just created (it has no content yet).
  #
  # `before` (regenerate, Plan §9): only include posts strictly older than this
  # timestamp, so regenerating an answer replays the conversation as it stood
  # when that answer was written — the reset target (now blank) and any later
  # turns are excluded. Strict `<`: a post sharing the target's exact created_at
  # is also excluded. created_at has microsecond precision and the target is
  # always inserted after its own question, so a real collision is effectively
  # impossible; if one ever occurred the question would simply be dropped from
  # context (a degraded but safe answer), never leak a later turn.
  #
  # NOTE: Chatpost#set_initial_role flips the first message's role to 'system' (a
  # legacy flag, not an actual system-prompt). We normalise that to 'user' here so
  # the LLM doesn't see two consecutive system messages. Real assistant/user
  # roles pass through unchanged.
  def build_messages(chat, rag_result = nil, before: nil, acting_user: nil)
    @analysis_reference_sources = []
    posts = chat.chatposts.where.not(id: MeetingTicketSuggestionRun.where.not(chatpost_id: nil).select(:chatpost_id)).order(:created_at)
    posts = posts.where('chatposts.created_at < ?', before) if before
    if @analysis_revision_answer
      # The explicit action selects a particular result, which may not be the last
      # answer. Replaying that result and this instruction removes any ambiguity.
      posts = [@analysis_revision_answer, posts.not_assistant.last].compact
    end
    @analysis_history = posts.reject { |post| post.assistant? && post.content.blank? }
    history = @analysis_history.map do |post|
      # Translation boundary: on the left the Chatpost enum, on the right the LLM wire role.
      # The two vocabularies only look alike — they must not share constants (see the header
      # on Chatpost#role). A system post is a legacy first-question flag, so it enters the
      # history as a user turn; everything that is not an assistant turn does.
      role = post.assistant? ? 'assistant' : 'user'
      content = post.content.to_s
      # Defensive re-strip on replay (assistant turns only — user text is never
      # altered): normally the folded final write already persisted stripped
      # content, but if the job died between stream end and that write, a raw
      # marker would survive in the DB and replaying it verbatim would coax the
      # model into imitating the format (review find, crash window).
      content = Lalabase::ProjectRag::SourceAttribution.strip(content) if role == 'assistant'
      { role: role, content: content }
    end
    # The synthetic instruction turn shares the same budget as real history.
    history.unshift(role: 'user', content: @analysis_revision_answer.analysis_context['instructions'].join("\n\n")) if @analysis_revision_answer
    history = cap_history(history)
    @analysis_history = @analysis_history.last(history.size)
    # Never inherit a revision target that the provider did not receive.
    raise RevisionContextTooLarge if @analysis_revision_answer && !@analysis_history.include?(@analysis_revision_answer)

    system = system_prompt_with_context(chat, rag_result, acting_user: acting_user)
    [{ role: 'system', content: system }, *history]
  end

  # D15: trim the replayed history to MAX_CONTEXT_TOKENS, dropping the OLDEST turns
  # first and always keeping at least the most recent one (the current question).
  # Char-based estimate (same CHARS_PER_TOKEN heuristic the provider uses) — a cheap
  # cap, not an exact tokeniser; slight over/undershoot is fine for a flat-price cap.
  def cap_history(history)
    return history if history.size <= 1

    budget_chars = MAX_CONTEXT_TOKENS * CONTEXT_CHARS_PER_TOKEN
    kept = history
    kept = kept.drop(1) while kept.size > 1 && kept.sum { |m| m[:content].to_s.length } > budget_chars
    kept
  end

  # The system prompt is rendered in the chat's pinned language so the LLM
  # replies in the same language the user opened the chat in (independent of
  # the requesting user's UI locale).
  def system_prompt_with_context(chat, rag_result, acting_user: nil)
    locale = (chat.language.presence || I18n.locale).to_s
    I18n.with_locale(locale) do
      # Plan §7: the persona/style block (persona intent + per-user style level +
      # injection guard) leads, then the core prompt
      # (role + vision/capabilities-first; style now lives in the per-user
      # directives, §8.1), then the M8.3.8 tool hint. The block varies per
      # chat AND per user and sits BEFORE the stable RAG context, so the provider
      # prompt-cache prefix only differs in the leading block, not mid-context.
      base = [
        persona_and_style_block(chat, locale, acting_user: acting_user),
        core_system_prompt(chat),
        tool_hint(chat)
      ].reject(&:blank?).join("\n\n")
      return base if rag_result.blank?

      # Every retrieved item is labelled with its project: the assistant prompt asks
      # the model to name origins, so the data must carry them. `name_projects` used
      # to be false for the single-project surface projekt_chat_abbau removed, which
      # had one project and so no origin to disambiguate.
      context = Lalabase::ProjectRag::PromptBuilder.new(result: rag_result, name_projects: true).call
      return base if context.empty?

      "#{base}\n\n#{context}"
    end
  end

  # One surface, one framing since projekt_chat_abbau: a personal companion with
  # org-wide reach (S3a T3: tools + content retrieval across the asker's projects,
  # §14 origin rule in the prompt). The whole profile is still pinned as a table in
  # spec/jobs/chat_response_job_surface_profile_spec.rb -- one row now, and that
  # file's header already says a surface that comes back is a new row there first.
  def core_system_prompt(chat)
    assistant_system_prompt(chat)
  end

  # S3a T5 (§9.3): the model has to be TOLD the narrowings the user set, for two
  # reasons that both end in an untruth otherwise. Without them it keeps claiming
  # the org-wide reach its base prompt describes while Tools::Scope has long since
  # intersected down. And it answers "sure, I will only look at Nordlicht from now
  # on" -- and then does not, because it has no way to change either narrowing and
  # never will (§14: the chat gets no mutating tool).
  #
  # ONE scope for both hints: they are two answers of the same object, and asking
  # twice would be two chances to resolve them against different reach.
  def assistant_system_prompt(chat)
    scope = Lalabase::Tools::Scope.for(chat: chat, actor: asker_for(chat))

    [I18n.t('jobs.ai_chat.assistant_system_prompt'), scope_hint(scope), reference_hint(scope)]
      .compact_blank.join(' ')
  end

  # Derived from the resolved selection, never from the stored column: a chosen
  # project that has since been archived is no longer a narrowing, and the prompt
  # must not announce one.
  def scope_hint(scope)
    chosen = scope&.selection
    return nil unless chosen

    (@analysis_reference_sources ||= []) << { 'type' => 'project', 'id' => chosen.id }

    I18n.t('jobs.ai_chat.assistant_scope_hint',
           project: chosen.one_line_name(max: MAX_PROMPT_PROJECT_NAME_CHARS))
  end

  # The reference earns its OWN sentence next to the chip's, because it says
  # something the chip does not. The chip narrows the REACH; the reference also
  # names the SUBJECT, and a follow-up question ("und wer arbeitet daran?") has no
  # antecedent without it. Both are owed even when they agree, which is the normal
  # case -- the button on the object's page sets both.
  #
  # Same rule as above, one level down: resolved through Tools::Scope#references,
  # never from the stored column. A reference that stopped resolving must leave NO
  # trace, its name least of all -- that name is exactly what the app withholds
  # from someone who may not read it.
  #
  # A LIST since S2 (plan §9), in STORED order, one line per object. Every entry
  # is named or the model has no antecedent for the ones it was not told about;
  # the order is the add order, because the chip shows that order and the two must
  # describe the same collection.
  #
  # ⚠️ Only IDENTITY, never content (E5). Five transcripts would blow up any
  # prompt, and the reading tools are how the model gets at what is inside.
  #
  # ⚠️ And identity means the UUID, in every line. After E3 the assistant searches
  # across all reachable projects again, so "#112" is ambiguous -- GetTicket
  # resolves numbers PER PROJECT (get_ticket.rb) and used to be disambiguated by
  # the reference's own narrowing, which is gone. A meeting has no number at all
  # (*Beleg:* the create_table "meetings" block in db/schema.rb carries none), and
  # GetTicket takes the uuid as its other address anyway -- the one that needs no
  # project to be unique.
  #
  # (Spelled out rather than naming the tool's id parameter: the S4-T1 teardown
  # guard forbids that token anywhere on the chat side, and a guard that lists
  # words cannot tell a comment from a column.)
  def reference_hint(scope)
    records = scope&.references.presence
    return nil unless records

    # Titles and project names enter the prompt even without a tool read. They
    # carry source rights too, but metadata alone never makes an answer savable.
    @analysis_reference_sources = Array(@analysis_reference_sources) + records.map do |record|
      { 'type' => Assistant::ReferenceRegistry.entry_for(record.class.name).citation_type,
        'id' => record.id, 'project_id' => record.project_id }
    end

    hint = I18n.t('jobs.ai_chat.assistant_reference_hint', count: records.size,
                                                           list: records.map { |record| reference_line(record) }.join('; '))
    # §9: the limit is measured at the chip row, not at the tool budget. Ten
    # references are up to ten get_* calls, and they all fit in ONE round -- the
    # Runner's five iterations are ROUNDS, and all tool_calls of one response run
    # inside one of them (corrected after the review of #642; the earlier comment
    # named that number as a brake it is not). What bounds them is
    # Runner::DEFAULT_MAX_TOOL_RESULT_CHARS, a total over the run's tool results.
    # So this sentence is the hint on top of a limit, not the only counter-measure
    # there is. Earned only from the SECOND entry on -- with one reference, reading
    # it is exactly the right thing to do.
    hint = "#{hint} #{I18n.t('jobs.ai_chat.assistant_reference_frugality')}" unless records.one?
    with_outside_notice(hint, scope, records)
  end

  # ⚠️ The prompt half of the E3 reach fix (review of #642). Since GetTicket may
  # read what the thread POINTS AT even when the chip searches elsewhere, an answer
  # can legitimately draw on a project the scope sentence just excluded. The model
  # is asked to say so when it does.
  #
  # A REQUEST, and named as one. The guarantee is the coverage line under the
  # answer, which the server renders from the same numbers
  # (Tools::Scope#coverage -> coverage_notice_outside): a sentence asked of a model
  # is not a limit, which is exactly the mistake this slice made once already about
  # the tool budget. Both halves exist on purpose -- the sentence helps inside the
  # prose, the line holds when the sentence is ignored.
  #
  # Only with a chip: without a narrowing there is no outside.
  def with_outside_notice(hint, scope, records)
    selection = scope&.selection
    return hint if selection.nil?
    return hint unless records.any? { |record| record.respond_to?(:project_id) && record.project_id != selection.id }

    "#{hint} #{I18n.t('jobs.ai_chat.assistant_reference_outside')}"
  end

  # How ONE object is named to the model, keyed by the registry's citation_type so
  # a new type brings its own line rather than being pressed into a shared shape
  # (a meeting needs a date where a ticket carries a number).
  #
  # The title goes through the type's own formatter (the registry's `title`
  # lambda), capped: `tickets.title` is free text and can be a pasted stacktrace.
  # The project name is capped the same way (Project#one_line_name). The numbers
  # are this surface's own -- a sentence affords more than the chip's pill.
  def reference_line(record)
    entry = Assistant::ReferenceRegistry.entry_for(record.class.name)

    I18n.t("jobs.ai_chat.reference_items.#{entry.citation_type}",
           title: entry.title.call(record, MAX_REFERENCE_TITLE_CHARS),
           project: record.project.one_line_name(max: MAX_PROMPT_PROJECT_NAME_CHARS), id: record.id)
  end

  # The org-wide assistant gets its OWN hint (S3a T3): the project hint promises
  # "this one project", which is exactly wrong there.
  #
  # The code sentence rides in the SAME branch that gets the code tools, and it has
  # to: the assistant hint says the tools work across every project the asker may
  # read, which is true of the four org-wide ones and false of the five code ones
  # (they answer for ONE project each). Left unsaid, the prompt promises a reach
  # that does not exist; said to an organisation without repositories, it advertises
  # tools that were never offered.
  #
  # The chat's full-text limit of get_ticket is read from the tool, not typed into
  # the text: the tool schema still names the MCP value, so the prompt is the one
  # place the model learns the number that applies here.
  def tool_hint(chat)
    hint = I18n.t('jobs.ai_chat.assistant_tool_hint', limit: full_text_limit_label)
    return hint unless code_tools?(chat)

    "#{hint} #{I18n.t('jobs.ai_chat.assistant_tool_hint_code')}"
  end

  # The one place the limit becomes text, in the current locale. Specs that
  # rebuild the hint ask here instead of formatting the number themselves: a
  # fourth hand-made copy without `limit:` turned the guards job red (#979).
  def full_text_limit_label
    ActiveSupport::NumberHelper.number_to_delimited(Lalabase::Tools::GetTicket::MAX_ASSISTANT_FULL_TEXT_CHARS)
  end

  # Delegates to the model's ONE predicate (Chat#org_thread?), which is trivially
  # true until step 5 of projekt_chat_abbau drops the column under it.
  def org_thread?(chat)
    chat.org_thread?
  end

  def runner_tool_set(chat)
    code_tools?(chat) ? :assistant_with_code : :assistant
  end

  # Whether this answer is offered the five code tools. ONE question with two
  # callers (the tool set and the tool hint), so it has one owner: a set advertised
  # without its sentence, or a sentence without the tools, are both worse than
  # either state alone.
  #
  # `ProjectRepository.exists?` and not "has code symbols": vision, capabilities and
  # symbols live in three tables and are all produced by indexing a repository, so
  # the repository is the one cheap question that covers all three. It over-offers
  # slightly for a connected but un-indexed repo, which is the right direction to
  # err -- the tools then answer "not indexed yet" instead of being missing.
  #
  # Per ORGANISATION, not per asker: an asker-scoped answer would need the candidate
  # set the tools compute anyway, and computing it twice per answer to save tokens
  # for one member is the wrong trade. A member with no repo-reachable project gets
  # the tools offered and the tools answer cleanly that there is none.
  def code_tools?(chat)
    org_thread?(chat) && ProjectRepository.exists?(organisation_id: chat.organisation_id)
  end

  # Plan §7/§8: the chat's persona fragment (its intent lens), then the
  # persistent per-user style directives (technicality + length), then the
  # injection guard. Rendered in `locale` (the chat's pinned language) — the
  # caller is already inside I18n.with_locale(locale). The persona fragment is
  # optional; the style directives and the guard always apply.
  def persona_and_style_block(chat, locale, acting_user: nil)
    # ONE resolve of the acting person's preference row per answer. The persona
    # and the two style levels are three fields of the SAME row, so resolving it
    # once is both a query saved and, more to the point, one place that decides
    # what "no acting user" means instead of two that can drift.
    preference = acting_user && ChatStylePreference.resolve_for(user: acting_user, organisation: chat.organisation)
    [
      resolved_persona_fragment(chat, locale, preference: preference),
      style_directives(preference),
      I18n.t('jobs.ai_chat.injection_guard')
    ].reject(&:blank?).join("\n\n")
  end

  # Plan §6.2/§8.1: the persistent per-user answer-style directives, read off the
  # acting person's already-resolved ChatStylePreference row (so a pill nudge
  # shifts every future answer). Falls back to the neutral 2/2 default when there
  # is no acting user (pre-v1.5 job, non-user trigger) or no stored row --
  # resolve_for never persists.
  #
  # Why ALWAYS non-blank (even at the neutral 2/2 default): v1.5 split the style
  # OUT of the core system_prompt — the core prompt no longer says "no code / no
  # jargon", otherwise it would contradict a technicality:3 directive. So the
  # per-user level is now the ONLY place style is stated, and every answer needs
  # it, including the default.
  #
  # Takes the ROW, not (chat, acting_user:), since 30.08.2026: the persona choice
  # lives on the same row, so the caller resolves it once and hands it to both.
  # `nil` is the valid back-compat path (no acting user), not an error. The org
  # still never comes from ActsAsTenant.current_tenant -- persona_and_style_block
  # passes it explicitly, so the dependency stays visible and cannot drift if the
  # ambient tenant ever changes mid-render.
  def style_directives(preference)
    technicality = preference&.technicality || ChatStylePreference::DEFAULT[:technicality]
    length = preference&.length || ChatStylePreference::DEFAULT[:length]
    [
      I18n.t("jobs.ai_chat.style.technicality.#{technicality}"),
      I18n.t("jobs.ai_chat.style.length.#{length}")
    ].join("\n")
  end

  # The persona's prompt fragment, resolved in three steps (assistant persona
  # settings, doc/assistent_persona_einstellungen_plan.md):
  #
  #   1. the thread's own pin, which wins because somebody chose it FOR this
  #      conversation. Nothing WRITES that pin since projekt_chat_abbau took the
  #      new-chat picker of the surface it removed; chats.prompt_persona_id and this stay
  #      exactly as they are, so "a persona for this conversation" on the assistant
  #      is a UI slice and not a schema change,
  #   2. the acting user's standing choice from the assistant's settings menu,
  #   3. the organisation's default persona (PromptPersona.default_for).
  #
  # nil when nothing resolves (e.g. an unseeded pool) — the chat then runs on the
  # core prompt alone, which is still non-technical.
  #
  # `preference` is the acting person's already-resolved row, or nil when there is
  # no acting user (a job enqueued before v1.5, a non-user trigger) -- which
  # simply means "no standing choice".
  #
  # #resolved_persona on BOTH carriers, never the raw association. A persona can
  # be retired org-wide, or superseded by an org row under the same key, after it
  # was picked; using the stored column anyway would keep a withdrawn prompt
  # fragment alive in every answer. Both steps fall through to the next one
  # instead, so a retired persona stops acting the moment it is retired rather
  # than the next time somebody opens a picker.
  #
  # This holds for the thread pin too, and that is the point: the rule is a
  # property of "a persona is attached", not of one of the two places that attach
  # one, so it lives in PromptPersonaSelectable and both callers ask it.
  def resolved_persona_fragment(chat, locale, preference: nil)
    persona = chat.resolved_persona ||
              preference&.resolved_persona ||
              PromptPersona.default_for(chat.organisation)
    persona&.prompt_fragment(locale)
  end

  # Runs language detection on the latest non-assistant chatpost when the
  # chat does not have a LOCKED language yet. Persists the result and
  # re-locks the chat so all subsequent answers stay in that language.
  #
  # Respects the unlock-to-redetect flow: a user with `language_locked = false`
  # (set via a settings action) triggers fresh detection on their next message.
  # Never raises — a detection failure should not break chat.
  def detect_and_lock_language(chat)
    return if chat.language.present? && chat.language_locked?

    # Shared helper, not an inline query: keeps the set_initial_role 'system'-flag caveat
    # documented in ONE place (last_non_assistant_post), not silently re-encoded here.
    last_user_post = last_non_assistant_post(chat)
    return if last_user_post.nil? || last_user_post.content.to_s.strip.empty?

    detected = Lalabase::LanguageDetector.call(last_user_post.content)
    # Defense in depth: update_columns bypasses validation. Refuse to persist
    # anything outside the Chat::LANGUAGES whitelist, even though the detector
    # contract guarantees it today. Log loudly so contract drift is visible
    # in production telemetry.
    unless Chat::LANGUAGES.include?(detected)
      Rails.logger.warn(
        "ChatResponseJob: detector returned non-whitelist value #{detected.inspect} for chat #{chat.id}"
      )
      return
    end

    # update_columns is deliberate: the language-lock must bypass validations
    # and the after_update broadcast (we don't want a language flip to re-render
    # the chat). See the defense-in-depth note above.
    chat.update_columns(language: detected, language_locked: true)
  rescue StandardError => e
    Rails.logger.warn "ChatResponseJob: language detection failed: #{e.class}: #{e.message}"
  end

  # Returns a Retriever::Result or nil. Never raises — RAG failure must not
  # break chat. A failed embedding call just downgrades to a context-free reply.
  #
  # `before` (regenerate, Plan §9): retrieve context for the question that the
  # target answer responded to — the latest non-assistant post strictly before
  # the target — not some later turn.
  def retrieve_rag_context(chat, before: nil, asker: nil)
    # Every thread retrieves through the retriever's org path (S3a T3, content layer
    # across the asker's per-area reach). The guard that stood here refused a
    # project-less chat that was not an org thread, a shape the schema no longer
    # allows and the surface no longer produces.
    last_user_post = last_non_assistant_post(chat, before: before)
    return nil if last_user_post.nil? || last_user_post.content.to_s.strip.empty?

    # asker gates the project-content layer (Plan §4.2): only content from areas the asker
    # may read is retrieved. Without an asker the content layer stays fail-closed (empty),
    # so this wiring is what actually switches the project-content RAG on.
    Lalabase::ProjectRag::Retriever.new(
      chat: chat,
      query: last_user_post.content.to_s,
      asker: asker
    ).call
  # Quota exhausted on the embedding side: degrade to a context-free reply (the
  # chat itself still runs if it's on a non-quota/BYOK provider). Info, not warn —
  # a paused quota is expected, not a failure.
  rescue Lalabase::Llm::QuotaExceededError => e
    Rails.logger.info "ChatResponseJob: RAG skipped, AI quota exhausted: #{e.message}"
    nil
  rescue Lalabase::Llm::Provider::Error => e
    Rails.logger.warn "ChatResponseJob: RAG embedding failed, falling back: #{e.message}"
    nil
  rescue Lalabase::Llm::Factory::MissingCredentialError => e
    Rails.logger.warn "ChatResponseJob: RAG skipped, no embedding credential: #{e.message}"
    nil
  rescue StandardError => e
    Rails.logger.error "ChatResponseJob: unexpected RAG error: #{e.class}: #{e.message}"
    nil
  end

  # The question's author — the same post the RAG query comes from (latest non-assistant
  # post before the cutoff), via its author. It is BOTH the principal the content-RAG gates
  # on (Retriever asker) AND the target of the a1 live stream. nil for an empty history.
  def asker_for(chat, before: nil)
    last_non_assistant_post(chat, before: before)&.user
  end

  # Latest non-assistant chatpost = the user's question. We can't filter strictly by
  # role='user' because Chatpost#set_initial_role flips the FIRST chatpost to role='system'
  # as a legacy flag — that row IS the user's first question and must trigger RAG.
  def last_non_assistant_post(chat, before: nil)
    posts = chat.chatposts.not_assistant.where.not(id: MeetingTicketSuggestionRun.where.not(chatpost_id: nil).select(:chatpost_id))
    posts = posts.where('chatposts.created_at < ?', before) if before
    posts.order(:created_at).last
  end

  def resolve_provider(organisation)
    Lalabase::Llm::Factory.for_feature(:chat, organisation)
  rescue Lalabase::Llm::Factory::MissingCredentialError => e
    Rails.logger.error "ChatResponseJob: no credential: #{e.message}"
    nil
  end

  # Tracks usage for billing/attribution. The model_used + token_usage columns
  # are persisted by respond's single folded update! — this method ONLY records
  # the AiUsage row (separation of concerns; avoids a redundant broadcast).
  # Delegates to the shared seam so the job and the migrated chat callers track
  # usage, attribute BYOK, and cost identically (S2 consolidation). Kept as a
  # method rather than inlined so specs can drive attribution via
  # send(:track_ai_usage, ...).
  def track_ai_usage(organisation, provider, result, chat: nil, acting_user: nil)
    Lalabase::Llm::UsageTracking.record(
      organisation: organisation,
      provider: provider,
      token_usage: result[:token_usage],
      model: result[:model_used],
      call_type: 'chat_streaming',
      action: Lalabase::Llm::ActionRegistry::CHAT_MESSAGE,
      user: acting_user,
      subject: chat
    )
  end

  # Error/unavailable copy must render in the chat's pinned language (M8.2
  # language-lock), same as the assistant's answers. The rescues + the
  # provider-nil branch run OUTSIDE system_prompt_with_context's locale block,
  # and a background job's ambient I18n.locale is the app default — so an
  # English-pinned chat would otherwise be served German error copy.
  def chat_locale(chat)
    chat.language.presence || I18n.locale
  end

  def update_or_create_error(chat, message, content)
    # Regenerate failure: bring the original answer back rather than destroying it
    # (the bubble was blanked before the call — see respond's snapshot note). Only
    # when there's a persisted target to restore; otherwise fall through.
    return restore_regenerated_answer(message) if @regenerate_restore && message&.persisted?

    # Known error copy contains no source material. Its explicit empty provenance
    # distinguishes it from a worker killed mid-stream (nil = unknown provenance).
    # Clear source_citations AND tool_calls on the error path: if the LLM
    # call failed (possibly mid-tool-loop), both describe a context/trace the
    # assistant never actually completed. Leaving them dangling on an error
    # message is misleading. (Runner contract: its accessors hold partial
    # state after a mid-loop raise — never persist them on this path.)
    if message&.persisted?
      message.update!(content: content, source_citations: [], tool_calls: [], source_coverage: nil,
                      model_used: nil, token_usage: {}, analysis_context: { 'provenance' => [] })
    else
      chat.chatposts.create!(organisation: chat.organisation, role: :assistant, content: content, analysis_context: { 'provenance' => [] })
    end
  end
end
