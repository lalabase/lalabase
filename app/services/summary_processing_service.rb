# frozen_string_literal: true

class SummaryProcessingService
  # NO model constant on purpose (doc/ki_provider_reichweite_plan.md, E2): the
  # model comes from the org's chat choice via the factory precedence
  # (org.preferred_chat_model > credential.default_model > provider constant).
  # A literal 'gpt-4o-mini' would be a runtime 404 on a Mistral/IONOS endpoint.
  MAX_TOKENS = 500
  TEMPERATURE = 0.7

  attr_reader :record

  def initialize(record)
    @record = record
    @text = record.plain_text_version
  end

  def process
    return unless @text.present?

    # GDPR opt-in gate: skip quietly like the sibling EmbeddingProcessingService.
    # Without this guard the AiDisabledError from the client seam would fall
    # into the broad rescue below and persist the RAW English exception text
    # into the user-visible summary_creation_error column on every upload.
    unless record.organisation&.ai_enabled?
      Rails.logger.debug do
        "SummaryProcessingService: skipping #{record.class.name}##{record.id} — AI disabled for organisation"
      end
      return
    end

    provider = resolve_provider
    return unless provider

    result = request_summary(provider)
    track_usage(provider, result)
    summary = result[:content].to_s.strip.presence

    if summary
      record.update!(generated_summary: summary, summary_creation_flag: true)
    else
      record.update!(summary_creation_error: I18n.t('services.summary_processing.summary_error'))
    end
  rescue Lalabase::Llm::QuotaExceededError
    # Quota paused: skip quietly like the AI-off case — a paused quota is not a
    # defect, so it must NOT land in summary_creation_error (mirror of the gate's
    # embedding pause). The summary can be regenerated once budget is available.
    Rails.logger.debug do
      "SummaryProcessingService: skipping #{record.class.name}##{record.id} — AI quota exhausted"
    end
  # Provider-level failure (S1): the model/endpoint the ORG chose does not answer —
  # e.g. an openai_compatible credential without a chat model, a missing api_base,
  # or a mapped auth error. Removing the hardcoded model made this reachable, and
  # the raw exception text is English and internal, so it must NOT go into the
  # user-visible column (same reasoning as the ai_enabled? guard above).
  # Ordered AFTER QuotaExceededError on purpose: QuotaExceededError and
  # AiDisabledError both inherit from Provider::Error, and Ruby takes the first
  # matching clause — the quiet skip must keep winning.
  rescue Lalabase::Llm::Provider::Error => e
    handle_provider_error(e)
  rescue StandardError => e
    handle_summary_error(e)
  end

  private

  # S2: routes through the single gated seam (Factory.for_feature since KI-Pakete
  # P3, Factory.for_chat before) instead of the removed
  # Organisation#ai_client_with_usage_tracking. The ai_enabled? guard in #process
  # runs first, so the AiDisabledError path is not normally reached here; a
  # missing SYSTEM credential still degrades gracefully to the unavailable copy.
  def resolve_provider
    # Follows the org's chat provider (S1 of doc/ki_provider_reichweite_plan.md).
    # The summarised text is arbitrary customer content from an upload, and the call
    # fires unattended on save — so the org admin's provider choice has to reach it,
    # otherwise a "EU only" setting silently ships documents to OpenAI.
    #
    # :document_summary is a utility row (P3): the summary is a reading aid beside
    # a document the user already has, and it fires on EVERY upload — the volume
    # path where the cheap rung pays off most. The package, and with it the
    # jurisdiction this comment is about, is untouched by that.
    Lalabase::Llm::Factory.for_feature(:document_summary, record.organisation)
  rescue Lalabase::Llm::Factory::MissingCredentialError
    Rails.logger.error('No LLM provider available for summary processing')
    record.update!(summary_creation_error: I18n.t('services.summary_processing.ai_unavailable'))
    nil
  end

  # No `model:` (see the constants block) and no `provider_options:` either.
  # provider_options is merged VERBATIM into the vendor request by every provider,
  # so those three OpenAI knobs would have travelled to Anthropic / Gemini and been
  # answered with a 400 on an unknown field. top_p: 1 and frequency_penalty: 0.0
  # were the OpenAI defaults anyway (no-ops), and presence_penalty's intent — don't
  # repeat yourself — is already spelled out in the prompt itself.
  # max_tokens/temperature stay: every provider maps them into its own dialect.
  def request_summary(provider)
    provider.chat(
      messages: [{ role: 'system', content: build_prompt }],
      max_tokens: MAX_TOKENS,
      temperature: TEMPERATURE
    )
  end

  def track_usage(provider, result)
    Lalabase::Llm::UsageTracking.record(
      organisation: record.organisation, provider: provider,
      token_usage: result[:token_usage], model: result[:model_used],
      call_type: 'document_summary',
      action: Lalabase::Llm::ActionRegistry::SUMMARY, subject: record
    )
  end

  def build_prompt
    <<~PROMPT.squish
      Wir haben ein Dokument, das folgende Inhalte enthält: #{@text}
      Erstelle mir eine inhaltliche Kurzfassung des Dokuments. Fasse Dich kurz.
      Nutze nicht mehr als 150 Worte. Hebe die Kernaussagen hervor.
      Nutze keine allgemeinen Aussagen, sei spezifisch.
      Ermittle abschließend die Seitenanzahl und teile mit, ob das Dokument Bilder oder Tabellen enthält.
      Versuche doppelte Informationen in deiner Antwort zu vermeiden.
      Wiederhole keine Informationen.
      Lasse die Anrede weg und setze direkt mit dem Text an.
    PROMPT
  end

  # Logs the real (English, internal) provider message for ops and persists the
  # localised copy the user actually sees in the document list.
  def handle_provider_error(error)
    Rails.logger.error(
      "Summary provider error for #{record.class.name} with ID #{record.id}: #{error.class}: #{error.message}"
    )

    record.update_columns(
      summary_creation_flag: false,
      summary_creation_error: I18n.t('services.summary_processing.provider_error')
    )
  end

  def handle_summary_error(error)
    Rails.logger.error(
      "Fehler bei der Summary-Erstellung für #{record.class.name} mit ID #{record.id}: #{error.message}"
    )

    record.update_columns(
      summary_creation_flag: false,
      summary_creation_error: error.message
    )
  end
end
