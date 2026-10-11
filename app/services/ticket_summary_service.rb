# frozen_string_literal: true

# Creates an AI summary for a ticket from the initial situation + conversation.
# Encapsulates API key check, prompt construction, the LLM call through the org's
# chosen chat provider, persistence and error mapping — the controller only
# translates the result into flash/response.
#
# Usage:
#   result = TicketSummaryService.new(ticket: ticket, organisation: org, updater: user).call
#   result.success? # => true, ticket.summary is set and saved
#   result.status   # => :success | :ai_disabled | :no_api_key | :not_configured |
#                        :invalid_key | :error | :save_failed
class TicketSummaryService
  # NO model constant on purpose (doc/ki_provider_reichweite_plan.md, E2): the
  # model comes from the org's chat choice via the factory precedence
  # (org.preferred_chat_model > credential.default_model > provider constant).
  # A literal 'gpt-4o-mini' would be a runtime 404 on a Mistral/IONOS endpoint.
  #
  # This block used to carry a third-copy unification marker for the whole
  # MODEL/MAX_TOKENS/TEMPERATURE/provider_options quartet. S1 and S2 dissolved
  # that duplication from the other end, by deleting the two provider-specific
  # members here and in both siblings. What remains are two provider-neutral
  # task parameters, and a shared home for them would couple three services that
  # are free to want different budgets.
  MAX_TOKENS = 500
  TEMPERATURE = 0.7

  Result = Struct.new(:status, keyword_init: true) do
    def success?
      status == :success
    end
  end

  def initialize(ticket:, organisation:, updater:)
    @ticket = ticket
    @organisation = organisation
    @updater = updater
  end

  def call
    # ONE question, asked of the very registry row this service routes on
    # (KI-Pakete P3). It used to be two — ai_enabled? plus the configuration-only
    # predicate ai_configured_for_chat? — and that second half asked about the
    # org's OWN chat rung while the call below runs on the package's UTILITY
    # rung. With a package whose two rungs sit on different credentials the two
    # disagreed in both directions: a broken cheap rung still offered the button,
    # and a broken expensive rung withheld it although the summary would have
    # worked. ai_available_for? reads the same row Factory.for_feature routes on,
    # so gate and routing cannot answer differently.
    #
    # Both STATUSES survive the merge — see #unavailable_status. The registry
    # answers the opt-in FIRST and with its own reason, which is the fail-closed
    # order this method already had.
    availability = organisation.ai_available_for?(:ticket_summary)
    return Result.new(status: unavailable_status(availability)) unless availability.available?

    # Follows the org's chat provider (P3 of doc/ki_provider_reichweite_plan.md).
    # The prompt carries the ticket content plus EVERY post on it, so the admin's
    # provider choice — which jurisdiction sees that — has to reach this call.
    #
    # By FEATURE KEY since KI-Pakete P3, and :ticket_summary is a utility row:
    # condensing a thread that is already on screen is help, not the product, so
    # a curated org runs it on its package's cheapest rung. Same package, same
    # jurisdiction — only the model within it is cheaper.
    provider = Lalabase::Llm::Factory.for_feature(:ticket_summary, organisation)
    result = request_summary(provider)
    track_usage(provider, result)

    ticket.summary = result[:content]
    # The timeline's summary block shows this date (mock 04.09.2026); nil for
    # summaries created before the column existed - the view skips the date then.
    ticket.summary_generated_at = Time.current
    ticket.updater = updater
    return Result.new(status: :save_failed) unless ticket.save

    Result.new(status: :success)
  rescue Lalabase::Llm::Factory::MissingCredentialError
    Result.new(status: :not_configured)
  rescue Lalabase::Llm::QuotaExceededError
    # Quota paused: the controller shows the quota hint instead of a generic error.
    Result.new(status: :quota_exceeded)
  rescue Lalabase::Llm::AiDisabledError
    # The gate above answers :ai_disabled first; this is defence in depth.
    Result.new(status: :ai_disabled)
  rescue Lalabase::Llm::Provider::AuthError => e
    # Provider maps the vendor's 401 to AuthError — the old Faraday::UnauthorizedError.
    Rails.logger.error "AI API key invalid while creating the summary: #{e.message}"
    Result.new(status: :invalid_key)
  rescue StandardError => e
    Rails.logger.error "Error creating the summary: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    Result.new(status: :error)
  end

  private

  attr_reader :ticket, :organisation, :updater

  # The two states this surface tells apart, mapped off the registry's reason.
  #
  # :ai_disabled keeps its own status because the ticket view renders a DIFFERENT
  # thing for it — the opt-in explanation, not the setup modal. Every other way to
  # be unavailable (no credential, unsupported provider) is one state here on
  # purpose: the surface has exactly one setup modal, so splitting further would
  # invent statuses nothing can render.
  #
  # Written as "is it the opt-in?" rather than as a list of the other reasons, so
  # a reason added to the registry lands in the setup-modal branch instead of
  # falling through to a nil status nobody handles.
  def unavailable_status(availability)
    availability.reason == :ai_disabled ? :ai_disabled : :no_api_key
  end

  # No `model:` (see the constants block) and no `provider_options:` either.
  # provider_options is merged VERBATIM into the vendor request by every provider,
  # so those three OpenAI knobs would have travelled to Anthropic / Gemini and been
  # answered with a 400 on an unknown field — the same defect class as the model
  # literal, only with a different status code. top_p: 1 and frequency_penalty: 0.0
  # were the OpenAI defaults anyway (no-ops); presence_penalty: 0.6 WAS behavioural,
  # so its intent moved into the prompt itself ("keine doppelten Informationen") —
  # the same place the sibling services keep it. A vendor knob that only takes
  # effect at one provider is the weaker version of the same instruction: as a
  # sentence it survives the switch AND reaches the other providers for the first
  # time (S1 made the identical trade in SummaryProcessingService and
  # Meetings::SummaryService).
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
      organisation: organisation, provider: provider,
      token_usage: result[:token_usage], model: result[:model_used],
      call_type: 'ticket_summary',
      action: Lalabase::Llm::ActionRegistry::SUMMARY, subject: ticket, user: updater
    )
  end

  # Was kept word-for-word identical to the previous inline version (including its
  # spelling) when this service was extracted, so the extraction alone could not
  # change the AI behaviour.
  #
  # S2 adds ONE sentence on purpose (below): it carries what presence_penalty: 0.6
  # used to do — see #request_summary. That knob only ever reached OpenAI; as a
  # sentence the instruction survives a provider switch AND reaches the other
  # providers for the first time. Pinned in the spec's prompt example, because an
  # unguarded string would make the whole trade deletable without a red test.
  def build_prompt
    prompt = +'Wir haben folgende Ausgangsaussage: '
    prompt << ticket.content.to_plain_text
    prompt << 'Darauf folgt folgende Konversation: '
    # Every reader of the ticket sees the summary: public comments only
    ticket.posts.public_posts.each do |post|
      prompt << "#{post.user.full_name}: #{post.content.to_plain_text}\n"
    end
    prompt << 'Schreibe eine Zusammenfassung der neuen Ausgangslage.'
    prompt << 'Benenne auch kurz die wichtigsten Punkte, in denen sich die neue Ausgangslage von der alten unterscheidet. Die Bescheibung soll kurz sein und ohne Einleitung.'
    # Carries what presence_penalty: 0.6 used to do (see #request_summary): as a
    # prompt sentence it works on every provider, not just OpenAI.
    prompt << 'Vermeide doppelte Informationen und wiederhole dich nicht.'
    prompt << "Leite den Abschnitt über die unterschiedlichen Punkt mit einem Absatz und der Überschrift 'Modifikation' ein."
    prompt
  end
end
