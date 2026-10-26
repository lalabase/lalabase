# frozen_string_literal: true

# Meetings::BaseLlmService — shared LLM ritual for the meeting AI pipeline: the
# ai_enabled gate, provider resolution, the SOURCE_CHAR_LIMIT source cap,
# UsageTracking, and the error-class → readable-status mapping. Slice 4
# (SummaryService) is the first user, Slice 7a (AnalysisService) the second — the
# "unify at the third case" trigger fired, so the control flow lives here ONCE and
# a summary and an analysis run can never drift on the parts that must stay
# identical (the review #235 lessons — cap-before-call, flag-always-cleared,
# no-raise — are all here).
#
# Persists STATUS on its record (no Result struct): it runs async from a job and
# has no request to answer. Subclasses supply the record, the source text, the
# prompt, the chat parameters, the status columns, the metering action and the
# i18n scope; the base owns the flow.
#
# Entry point: each subclass exposes a typed `.call(...)` that instantiates and
# runs `#process` here (this base is abstract — instantiating it and calling the
# hooks below raises NotImplementedError).
module Meetings
  # S1b (doc/ki_provider_reichweite_plan.md): the former `PROVIDER = 'openai'`
  # constant is GONE, not renamed. It carried two meanings at once — the routing
  # target here and the gate argument at every caller (`ai_available?(PROVIDER)`)
  # — and after S1b/S1c neither is a constant any more: routing asks
  # Factory.for_feature(feature_key, org) below, and since R2 the gate asks Organisation#ai_available_for?
  # with the SUBCLASS's own feature key (:meeting_summary / :meeting_analysis /
  # :meeting_ticket_suggestions — three rows, because their configuration may
  # diverge). A renamed constant would have preserved the ambiguity in a new spelling.
  class BaseLlmService
    # Cap the source BEFORE the LLM call: a 1 MB transcript (~250k tokens) exceeds
    # the model context (128k) and would 400 on every attempt; anything near the
    # window burns ~128k input tokens per click. 100k chars (~25-30k tokens) is far
    # more than a summary/analysis needs and bounds the cost (review #235).
    SOURCE_CHAR_LIMIT = 100_000

    # The canonical stop_reason of an answer that hit max_tokens (Provider#chat).
    # Such an answer stops mid-sentence (or mid-JSON); it used to be stored as a
    # finished result without a hint.
    TRUNCATED_STOP_REASON = 'length'

    # Template. Mirrors the original SummaryService#process one-to-one; the only
    # difference is that the varying parts are hook methods.
    def process
      source = self.source
      # Nothing to work on → clear the pending flag AND any leftover error, so the
      # view falls through to the no-content hint instead of a stale failure text.
      return persist_no_source if source.blank?

      # GDPR opt-in gate (defence in depth; the UI is gated on ai_available?).
      return record_error(t('ai_disabled')) unless organisation&.ai_enabled?

      # Routes through the ORG's chat provider (S1b of
      # doc/ki_provider_reichweite_plan.md). All three subclasses ship a meeting
      # TRANSCRIPT — the most GDPR-sensitive payload in the app — so the
      # controller of the data must pick its processor; a pin to OpenAI made the
      # org's provider choice a false statement on these three paths at once.
      #
      # By FEATURE KEY since KI-Pakete P3: the subclass declares its own key, so
      # this one line routes all three — and each subclass's gate reads the very
      # row its request will route on. What differs per row is the RUNG, not the
      # provider: :meeting_ticket_suggestions is utility (cheapest rung),
      # :meeting_summary and :meeting_analysis take the org's own. for_feature
      # carries the opt-in + quota gates exactly as for_chat did.
      provider = Lalabase::Llm::Factory.for_feature(feature_key, organisation)
      result = provider.chat(**chat_arguments(build_prompt(source)))
      # Meter BEFORE handling the result — a malformed/empty answer still cost
      # tokens (track-before-parse, the ParticipantDetectionService rule).
      track_usage(provider, result)
      # A cut answer is never a finished one: checked after metering (it cost
      # tokens) and before handle_result, so every subclass gets it, including
      # one that overrides handle_result.
      return record_truncated(result) if result[:stop_reason] == TRUNCATED_STOP_REASON

      handle_result(result)
    rescue Lalabase::Llm::Provider::TruncatedError => e
      # The limit was reached before any text: the provider raises instead of
      # returning, but the call was billed all the same. Same outcome as above.
      track_usage(provider, e.result)
      record_truncated(e.result)
    rescue Lalabase::Llm::Factory::MissingCredentialError
      record_error(t('not_configured'))
    rescue Lalabase::Llm::QuotaExceededError
      # S3 KI-Kontingent: the gated seam blocks when the org's quota is exhausted —
      # record a quota-specific state instead of the generic error copy.
      record_error(t('quota_exhausted'))
    rescue Lalabase::Llm::AiDisabledError
      # ai_enabled? returns ai_disabled above first; this is defence in depth.
      record_error(t('ai_disabled'))
    rescue Lalabase::Llm::Provider::RequestRefusedError => e
      # The endpoint refused the request (a model whose output limit is below
      # the answer budget, a prompt beyond its context, an exhausted balance).
      # Waiting changes nothing, so not the generic "try again later". Who can
      # fix it decides the copy, as in ChatResponseJob#refused_copy; the
      # provider's own words stay in the log.
      Rails.logger.error "#{log_prefix}: provider refused the request: #{e.message}"
      record_error(t(own_access? ? 'request_refused_own_access' : 'request_refused'))
    rescue Lalabase::Llm::Provider::AuthError => e
      Rails.logger.error "#{log_prefix}: invalid AI key: #{e.message}"
      record_error(t('invalid_key'))
    rescue StandardError => e
      Rails.logger.error "#{log_prefix}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      record_error(t('generic_error'))
    end

    private

    # --- Hooks the subclass MUST implement --------------------------------------

    # The FeatureRegistry key of this subclass — the row that both the caller's
    # gate (Organisation#ai_available_for?) and the routing above read. Each of
    # the three has its own row because their configuration may diverge, and
    # since P3 it already does: two of them take the org's rung, one the utility
    # rung. No default: a subclass that forgot to declare a key would otherwise
    # silently route on a sibling's decision.
    def feature_key
      raise NotImplementedError, "#{self.class} must implement #feature_key"
    end

    # The record the status is persisted on (Meeting for a summary, MeetingAnalysis
    # for an analysis). Its #organisation drives the tenant + AI gate.
    def record
      raise NotImplementedError, "#{self.class} must implement #record"
    end

    # The raw text the LLM works on (transcript-first for a meeting, the meeting's
    # summary_source for an analysis). Blank → the no-source branch.
    def source
      raise NotImplementedError, "#{self.class} must implement #source"
    end

    # The full LLM prompt built from `source` (already includes any cap notice).
    def build_prompt(_source)
      raise NotImplementedError, "#{self.class} must implement #build_prompt"
    end

    # Keyword arguments for provider.chat (messages/max_tokens/temperature).
    # NO `model:` and no `provider_options:` — see the subclasses' constant
    # blocks: the model comes from the factory precedence, and provider_options
    # is merged VERBATIM into the vendor request, so OpenAI-dialect knobs would
    # reach Anthropic/Gemini as unknown fields (400).
    def chat_arguments(_prompt)
      raise NotImplementedError, "#{self.class} must implement #chat_arguments"
    end

    # Status column names — deliberately differ per record (Meeting uses the
    # summary_* trio, MeetingAnalysis the bare creation_* pair).
    def flag_attr
      raise NotImplementedError, "#{self.class} must implement #flag_attr"
    end

    def error_attr
      raise NotImplementedError, "#{self.class} must implement #error_attr"
    end

    def content_attr
      raise NotImplementedError, "#{self.class} must implement #content_attr"
    end

    # Metering (#231): the flat ActionRegistry action + the usage call_type label.
    def usage_action
      raise NotImplementedError, "#{self.class} must implement #usage_action"
    end

    def call_type
      raise NotImplementedError, "#{self.class} must implement #call_type"
    end

    # Sub-scope under services.meetings.* for the readable status messages.
    def i18n_scope
      raise NotImplementedError, "#{self.class} must implement #i18n_scope"
    end

    # --- Shared helpers ---------------------------------------------------------

    # What to do with a successful LLM result. Default (summary/analysis): persist
    # the single content string on the record. A subclass whose "content" is not a
    # single column overrides this — TicketSuggestionService parses a JSON array,
    # matches each entry against existing tickets, and atomically replaces the open
    # suggestion rows. It runs AFTER track_usage (metering always happens first) and
    # inside `process`'s rescue chain, so any failure sets the record's error status
    # WITHOUT a partial write.
    def handle_result(result)
      content = result[:content].to_s.strip.presence
      return record_error(t('empty_result')) unless content

      persist_success(content)
    end

    def organisation
      record.organisation
    end

    # Does this request run on the organisation's own access (on the rung of
    # this feature)? Same question ChatResponseJob#refused_copy asks.
    def own_access?
      utility = Lalabase::Llm::FeatureRegistry.fetch(feature_key).utility?
      Lalabase::Llm::Factory.own_chat_access?(organisation, utility: utility)
    end

    # Caps `text` at SOURCE_CHAR_LIMIT. Returns [capped_text, truncated?] so the
    # subclass can phrase its own truncation notice on the prompt.
    def cap_source(text)
      return [text, false] if text.length <= SOURCE_CHAR_LIMIT

      [text[0, SOURCE_CHAR_LIMIT], true]
    end

    def track_usage(provider, result)
      Lalabase::Llm::UsageTracking.record(
        organisation: organisation, provider: provider,
        token_usage: result[:token_usage], model: result[:model_used],
        call_type: call_type, action: usage_action, subject: record
      )
    end

    # Persist a fresh result: content + clear the pending flag and error. update!
    # (not update_columns) so callbacks fire (Meeting broadcasts the summary).
    def persist_success(content)
      record.update!(content_attr => content, flag_attr => false, error_attr => '')
    end

    # Clear the pending flag AND record a readable error.
    def record_error(message)
      record.update!(flag_attr => false, error_attr => message)
    end

    # Keep no part of a cut answer: readable error, flag cleared, earlier content
    # untouched. The log names the token counts, never the answer itself.
    def record_truncated(result)
      usage = result[:token_usage] || {}
      Rails.logger.warn "#{log_prefix}: answer cut at the output limit " \
                        "(input #{usage[:input_tokens].inspect}, output #{usage[:output_tokens].inspect}, " \
                        "total #{usage[:total_tokens].inspect})"
      record_error(t('truncated'))
    end

    # Nothing to process: clear the pending flag AND any leftover error.
    def persist_no_source
      record.update!(flag_attr => false, error_attr => '')
    end

    def t(key)
      I18n.t("services.meetings.#{i18n_scope}.#{key}")
    end

    def log_prefix
      "#{self.class}: #{record.class}##{record&.id}"
    end
  end
end
