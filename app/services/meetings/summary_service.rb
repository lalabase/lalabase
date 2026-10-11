# frozen_string_literal: true

# Meetings::SummaryService — async AI summary for a meeting (transcript-first,
# notes-fallback), built on Meetings::BaseLlmService. Entry point: .call(meeting:).
module Meetings
  # Creates the single AI summary for a meeting from its transcript (preferred)
  # or its notes (fallback) — plan decision 11, so a meeting WITHOUT a transcript
  # still gets a summary. Runs async from Meetings::SummaryJob and persists the
  # DocumentVersion-style column trio on `meetings`; the controller/view only read
  # those columns.
  #
  # The LLM ritual (ai_enabled gate, provider resolution, source cap, UsageTracking,
  # error→status mapping) lives in Meetings::BaseLlmService — this class only
  # supplies the summary specifics (source rule, prompt, chat params, columns).
  #
  # A dedicated service, NOT the generic SummaryProcessingService: that one reads
  # `plain_text_version`, which for a meeting is notes AND transcript concatenated
  # and would violate the transcript-first / notes-fallback source rule.
  #
  # Flag semantics DIFFER from DocumentVersion on purpose: here
  # `summary_creation_flag` means "generation pending" (set true by the controller
  # on enqueue, cleared here on completion) so the view can show a live
  # "wird erstellt…" state. In DocumentVersion the flag means "summary present".
  #
  # Entry point: .call(meeting:) → BaseLlmService#process.
  class SummaryService < BaseLlmService
    # NO model constant on purpose (doc/ki_provider_reichweite_plan.md, E2): the
    # model comes from the org's chat choice via the factory precedence
    # (org.preferred_chat_model > credential.default_model > provider constant).
    # A literal 'gpt-4o-mini' would be a runtime 404 on a Mistral/IONOS endpoint,
    # and the task profile is provider-neutral anyway: a transcript in, 150 words
    # of German prose out — every chat model can do that.
    MAX_TOKENS = 500
    TEMPERATURE = 0.7

    def self.call(meeting:)
      new(meeting: meeting).process
    end

    def initialize(meeting:)
      super()
      @meeting = meeting
    end

    private

    # Not utility: the summary is what the customer reads, so the quality rung is
    # theirs to choose (registry, P3).
    def feature_key
      :meeting_summary
    end

    def record
      @meeting
    end

    def source
      @meeting.summary_source
    end

    def flag_attr
      :summary_creation_flag
    end

    def error_attr
      :summary_creation_error
    end

    def content_attr
      :generated_summary
    end

    def usage_action
      # S3 KI-Kontingent: a meeting summary bills the flat 'summary' action (like
      # document/ticket summaries).
      Lalabase::Llm::ActionRegistry::SUMMARY
    end

    def call_type
      'meeting_summary'
    end

    def i18n_scope
      'summary'
    end

    # No `model:` (see the constants block) and no `provider_options:` either.
    # provider_options is merged VERBATIM into the vendor request by every
    # provider, so those three OpenAI knobs would have travelled to Anthropic /
    # Gemini and been answered with a 400 on an unknown field. top_p: 1 and
    # frequency_penalty: 0.0 were the OpenAI defaults anyway (no-ops); only
    # presence_penalty: 0.6 was behavioural, and on a summary the prompt itself
    # caps at 150 words, so its repetition-damping effect is marginal — a
    # measurable nudge in wording for OpenAI orgs, traded for a lane that works
    # on every provider at all (same call as SummaryProcessingService in S1).
    # max_tokens/temperature stay: every provider maps them into its own dialect.
    def chat_arguments(prompt)
      { messages: [{ role: 'system', content: prompt }],
        max_tokens: MAX_TOKENS, temperature: TEMPERATURE }
    end

    # Plain German meeting-summary prompt — the single Slice 4 default (Slice 7a
    # makes prompts selectable via Meetings::AnalysisService; here one good default
    # is enough). Only the instruction text is squished; the source is appended RAW
    # below it — squishing the interpolated source used to collapse the transcript's
    # speaker-turn newlines into one line, degrading attribution (review #235).
    def build_prompt(source)
      instructions = <<~PROMPT.squish
        Das Folgende sind die Mitschrift bzw. die Notizen eines Gesprächs.
        Erstelle eine kurze, sachliche Zusammenfassung des Gesprächs auf Deutsch.
        Nenne die besprochenen Themen, getroffene Entscheidungen und offene Punkte,
        soweit erkennbar. Fasse Dich kurz und nutze nicht mehr als 150 Worte.
        Lasse eine Anrede weg und setze direkt mit dem Inhalt an.
      PROMPT

      capped, truncated = cap_source(source)
      instructions += ' (Hinweis: Die Quelle wurde aus Platzgründen gekürzt.)' if truncated
      "#{instructions}\n\n#{capped}"
    end
  end
end
