# frozen_string_literal: true

# Meetings::AnalysisService — async AI analysis of a meeting from a chosen prompt,
# built on Meetings::BaseLlmService. Entry point: .call(analysis:).
module Meetings
  # Runs the LLM for ONE MeetingAnalysis: source = the meeting's summary_source
  # (transcript preferred, notes fallback — the SAME method, no twin), prompt =
  # a system frame + the frozen prompt_snapshot + the source appended RAW (no
  # squish on the source, so speaker-turn newlines survive — review #235). The
  # base owns the gate/cap/UsageTracking/error-mapping; this class supplies the
  # analysis specifics and persists the status pair on the MeetingAnalysis record.
  class AnalysisService < BaseLlmService
    # NO model constant on purpose (doc/ki_provider_reichweite_plan.md, E2): the
    # model comes from the org's chat choice via the factory precedence
    # (org.preferred_chat_model > credential.default_model > provider constant).
    # A literal 'gpt-4o-mini' would be a runtime 404 on a Mistral/IONOS endpoint,
    # and the task profile is provider-neutral anyway: a prompt in, German prose
    # out — every chat model can do that.
    # An analysis (protocol, decision list, redacted version) can run longer than a
    # 150-word summary; still bounded, and the SOURCE_CHAR_LIMIT cap bounds input.
    MAX_TOKENS = 1_500
    TEMPERATURE = 0.5

    def self.call(analysis:)
      new(analysis: analysis).process
    end

    def initialize(analysis:)
      super()
      @analysis = analysis
    end

    private

    # Not utility: an analysis is the product the customer judges the AI by
    # (registry, P3).
    def feature_key
      :meeting_analysis
    end

    def record
      @analysis
    end

    def source
      @analysis.meeting.summary_source
    end

    def flag_attr
      :creation_flag
    end

    def error_attr
      :creation_error
    end

    def content_attr
      :content
    end

    def usage_action
      # #231 metering: a meeting analysis bills the flat 'meeting_analysis' action.
      Lalabase::Llm::ActionRegistry::MEETING_ANALYSIS
    end

    def call_type
      'meeting_analysis'
    end

    def i18n_scope
      'analysis'
    end

    # No `model:` — see the constants block. max_tokens/temperature are
    # provider-neutral: every provider maps them into its own dialect
    # (Anthropic max_tokens, Gemini generationConfig.maxOutputTokens/temperature).
    def chat_arguments(prompt)
      { messages: [{ role: 'system', content: prompt }],
        max_tokens: MAX_TOKENS, temperature: TEMPERATURE }
    end

    # System frame (squished) + the frozen prompt_snapshot (RAW — it is the user's
    # instruction) + the source appended RAW below. Only the frame is squished.
    def build_prompt(source)
      instructions = <<~PROMPT.squish
        Du analysierst die Mitschrift bzw. die Notizen eines Gesprächs anhand der
        folgenden Arbeitsanweisung. Antworte auf Deutsch, sachlich und strukturiert;
        nutze ausschließlich Informationen aus dem Gespräch und erfinde nichts hinzu.
      PROMPT
      prompt = "#{instructions}\n\nArbeitsanweisung:\n#{@analysis.prompt_snapshot}"

      capped, truncated = cap_source(source)
      prompt += "\n\n(Hinweis: Die Quelle wurde aus Platzgründen gekürzt.)" if truncated
      "#{prompt}\n\n#{capped}"
    end
  end
end
