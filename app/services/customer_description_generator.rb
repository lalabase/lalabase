# frozen_string_literal: true

# ================================
# CUSTOMER DESCRIPTION GENERATOR
# ================================
# This service generates customer-friendly descriptions for TimeSessions
# using OpenAI's GPT-4o model. It analyzes ticket context, posts, and
# user descriptions to create concise, professional summaries suitable
# for client-facing reports and invoices.
#
# Key Features:
# - Generates descriptions up to 160 characters
# - Includes ticket title, content, and relevant posts
# - Excludes private posts and personal names
# - Professional, factual tone (German language)
# - Fallback to user description on errors
# - Retry mechanism for API timeouts
#
# Usage:
#   generator = CustomerDescriptionGenerator.new(time_session)
#   description = generator.generate
#   time_session.update(customer_description: description)
#
# Requirements:
# - OpenAI API credentials configured in organisation
# - time_session with valid occurred_on date
# - Optional: ticket with title/content and posts
# ================================

class CustomerDescriptionGenerator
  MAX_LENGTH = 250 # Maximum 250 characters for complete sentences
  MIN_LENGTH_FOR_LONG_SESSIONS = 500 # For sessions > 2 hours
  LONG_SESSION_THRESHOLD = 7200 # 2 hours in seconds
  MAX_RETRIES = 3
  MODEL = 'gpt-5-nano'

  # THE pin does not live here any more (R3, doc/ai_feature_registry_plan.md §5.2).
  # It is one line in Lalabase::Llm::FeatureRegistry — the `pin:` of the
  # :customer_description entry — and that is the SAME row
  # Organisation#ai_available_for? gates on. Removing the pin is therefore one edit
  # with no second place to forget it, which a constant shared between the gate and
  # the route could describe but never guarantee.
  #
  # Why it is pinned at all is recorded there as `pin_reason:`: gpt-5-nano is a
  # reasoning model, reasoning_effort travels via provider_options, and
  # OpenAiProvider switches to the max_completion_tokens dialect (no temperature)
  # for it. Sending that to Anthropic or Gemini does not degrade — it breaks.

  def initialize(time_session)
    @time_session = time_session
    @ticket = time_session.ticket
    @organisation = time_session.organisation
  end

  # Generate customer description with fallback and retry logic
  #
  # @return [String, nil] Generated description or nil on error
  def generate
    # GDPR opt-in gate: skip quietly for KI-off orgs so the seam's AiDisabledError
    # doesn't land in the rescue below as per-time-session error-log noise.
    return nil unless @organisation&.ai_enabled?

    generate_with_retry
  rescue Lalabase::Llm::QuotaExceededError
    # Quota paused: best-effort feature, skip quietly (customer_description stays
    # empty) rather than logging an error for an expected state.
    Rails.logger.debug { "CustomerDescriptionGenerator: skipping TimeSession #{@time_session.id} — AI quota exhausted" }
    nil
  rescue StandardError => e
    Rails.logger.error("CustomerDescriptionGenerator failed for TimeSession #{@time_session.id}: #{e.message}")
    nil # Return nil instead of fallback, so customer_description stays empty
  end

  private

  # Generate description with retry logic for timeouts
  #
  # @return [String] Generated description
  def generate_with_retry
    retries = 0
    begin
      generate_description
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      retries += 1
      if retries < MAX_RETRIES
        Rails.logger.warn("Retry #{retries}/#{MAX_RETRIES} for TimeSession #{@time_session.id}: #{e.message}")
        retry
      end
      nil # Return nil instead of fallback after max retries
    end
  end

  # Core method to generate description via OpenAI
  #
  # @return [String] Generated description from OpenAI
  def generate_description
    context = build_context
    prompt = build_prompt(context)
    response = call_openai(prompt)
    clean_and_truncate(response)
  end

  # Build context data from ticket, posts, and user description
  #
  # @return [Hash] Context data for prompt generation
  def build_context
    {
      ticket_title: @ticket&.title,
      ticket_content: extract_ticket_content,
      relevant_posts: fetch_relevant_posts,
      user_description: @time_session.description,
      has_ticket: @ticket.present?
    }
  end

  # Extract plain text from ticket content (ActionText)
  #
  # @return [String, nil] Plain text content or nil
  def extract_ticket_content
    return nil unless @ticket&.content

    @ticket.content.to_plain_text
  end

  # Fetch posts that are relevant for this time session
  # Only includes:
  # - Public posts (is_private = false)
  # - ALL posts created before or on the day of the time session
  #
  # @return [Array<String>] Array of post plain text content
  def fetch_relevant_posts
    return [] unless @ticket

    # Get end of day for the occurred_on date to include all posts from that day
    end_of_session_day = @time_session.occurred_on.end_of_day

    @ticket.posts
           .public_posts
           .where('created_at <= ?', end_of_session_day)
           .order(created_at: :asc)
           .pluck(:plain_text_version) # No limit - include all relevant posts
  end

  # Build prompt for OpenAI API
  #
  # @param context [Hash] Context data
  # @return [String] Formatted prompt
  def build_prompt(context)
    if context[:has_ticket]
      build_prompt_with_ticket(context)
    else
      build_prompt_without_ticket(context)
    end
  end

  # Build prompt when ticket context is available
  #
  # @param context [Hash] Context data
  # @return [String] Formatted prompt
  def build_prompt_with_ticket(context)
    is_long_session = @time_session.duration && @time_session.duration > LONG_SESSION_THRESHOLD
    length_requirement = is_long_session ? MIN_LENGTH_FOR_LONG_SESSIONS : MAX_LENGTH

    <<~PROMPT
      Erstelle eine kundenfreundliche Beschreibung für durchgeführte Arbeiten.

      REGELN:
      - #{is_long_session ? "Mindestens #{length_requirement} Zeichen (da Session > 2 Stunden)" : "Maximal #{length_requirement} Zeichen"}
      - Schreibe in der Vergangenheitsform (was wurde getan)
      - Schreibe aus der Perspektive des Dienstleisters (z.B. "Wir haben...", "Es wurde...")
      - Keine Personennamen erwähnen
      - Sachlicher, nüchterner Stil
      - Fokus auf: Was wurde konkret gemacht?
      - Vermeide technische Details und interne Prozesse
      - Vermeide Meta-Formulierungen wie "Die Arbeitszeit beschreibt..."
      - Sprache: Deutsch
      - WICHTIG: Schreibe nur vollständige, grammatikalisch korrekte Sätze
      - WICHTIG: Beende jeden Satz mit einem Punkt
      - Schneide Sätze niemals mittendrin ab
      - Nur die Beschreibung zurückgeben, keine zusätzlichen Erklärungen

      KONTEXT:

      Ticket-Titel: #{context[:ticket_title]}

      #{context[:ticket_content].present? ? "Ticket-Details:\n#{truncate_text(context[:ticket_content], 500)}\n\n" : ''}
      #{context[:relevant_posts].any? ? "Relevante Kommunikation:\n#{format_posts(context[:relevant_posts])}\n\n" : ''}
      Beschreibung des Mitarbeiters: #{context[:user_description]}

      Erstelle jetzt die Kundenbeschreibung (#{is_long_session ? "mind. #{length_requirement}" : "max. #{length_requirement}"} Zeichen, vollständige Sätze, Vergangenheitsform):
    PROMPT
  end

  # Build prompt when no ticket is linked
  #
  # @param context [Hash] Context data
  # @return [String] Formatted prompt
  def build_prompt_without_ticket(context)
    is_long_session = @time_session.duration && @time_session.duration > LONG_SESSION_THRESHOLD
    length_requirement = is_long_session ? MIN_LENGTH_FOR_LONG_SESSIONS : MAX_LENGTH

    <<~PROMPT
      Erstelle eine kundenfreundliche Beschreibung für durchgeführte Arbeiten.

      REGELN:
      - #{is_long_session ? "Mindestens #{length_requirement} Zeichen (da Session > 2 Stunden)" : "Maximal #{length_requirement} Zeichen"}
      - Schreibe in der Vergangenheitsform (was wurde getan)
      - Schreibe aus der Perspektive des Dienstleisters (z.B. "Wir haben...", "Es wurde...")
      - Keine Personennamen erwähnen
      - Sachlicher, nüchterner Stil
      - Fokus auf: Was wurde konkret gemacht?
      - Vermeide technische Details
      - Vermeide Meta-Formulierungen wie "Die Arbeitszeit beschreibt..."
      - Sprache: Deutsch
      - WICHTIG: Schreibe nur vollständige, grammatikalisch korrekte Sätze
      - WICHTIG: Beende jeden Satz mit einem Punkt
      - Schneide Sätze niemals mittendrin ab
      - Nur die Beschreibung zurückgeben, keine zusätzlichen Erklärungen

      Beschreibung des Mitarbeiters: #{context[:user_description]}

      Erstelle eine professionelle Kundenbeschreibung (#{is_long_session ? "mind. #{length_requirement}" : "max. #{length_requirement}"} Zeichen, vollständige Sätze, Vergangenheitsform):
    PROMPT
  end

  # Format posts for inclusion in prompt
  #
  # @param posts [Array<String>] Post contents
  # @return [String] Formatted posts
  def format_posts(posts)
    # Include ALL posts, but truncate each to 300 characters for better context
    posts.map.with_index do |post, index|
      truncated = truncate_text(post, 300)
      "Post #{index + 1}: #{truncated}"
    end.join("\n---\n")
  end

  # Truncate text to specified length
  #
  # @param text [String] Text to truncate
  # @param length [Integer] Max length
  # @return [String] Truncated text
  def truncate_text(text, length)
    return '' if text.blank?

    text.strip.truncate(length, omission: '...')
  end

  # Call OpenAI API with built prompt
  #
  # @param prompt [String] The prompt to send
  # @return [String] Response from OpenAI
  def call_openai(prompt)
    # Routed by FEATURE KEY, not by a provider literal (R3): for_feature reads the
    # registry row that also answers the gate, so the button that offers this and the
    # call that performs it cannot disagree about where the data goes — they read the
    # same line. Orgs routing elsewhere never reach here anyway: the actor refuses up
    # front, the bulk generator carries the twin for the async path.
    provider = Lalabase::Llm::Factory.for_feature(:customer_description, @organisation)

    start_time = Time.current
    result = provider.chat(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ],
      model: MODEL,
      max_tokens: 1000,
      # gpt-5-nano is a reasoning model: the provider maps max_tokens →
      # max_completion_tokens and omits temperature; reasoning_effort passes through
      # provider_options so the "fast, direct" behaviour is preserved 1:1.
      provider_options: { reasoning_effort: 'minimal' }
    )
    track_usage(provider, result)

    duration = Time.current - start_time
    log_api_call(duration, result)

    result[:content].to_s.strip.presence
  rescue Lalabase::Llm::Provider::AuthError => e
    Rails.logger.error "OpenAI API Unauthorized for TimeSession #{@time_session.id}: #{e.message}"
    nil
  rescue Lalabase::Llm::Provider::RateLimitError => e
    Rails.logger.error "OpenAI Rate Limit reached for TimeSession #{@time_session.id}: #{e.message}"
    nil
  end

  def track_usage(provider, result)
    Lalabase::Llm::UsageTracking.record(
      organisation: @organisation, provider: provider,
      token_usage: result[:token_usage], model: result[:model_used],
      call_type: 'customer_description',
      action: Lalabase::Llm::ActionRegistry::CUSTOMER_DESCRIPTION, subject: @time_session
    )
  end

  # System prompt for OpenAI
  #
  # @return [String] System prompt
  def system_prompt
    <<~PROMPT
      Du bist ein professioneller Dienstleister, der durchgeführte Arbeiten für Kunden dokumentiert.
      Deine Aufgabe ist es, aus technischen Informationen sachliche, kundenfreundliche
      Beschreibungen zu erstellen. Schreibe aus der Sicht des Dienstleisters in der Vergangenheit.
      Erwähne niemals Personennamen. Bleibe sachlich und nüchtern.
      Vermeide Formulierungen wie "Die Arbeitszeit beschreibt..." - beschreibe direkt die durchgeführten Tätigkeiten.
    PROMPT
  end

  # Clean and truncate response to appropriate length
  # Only truncates at sentence boundaries to avoid incomplete sentences
  #
  # @param text [String] Raw response
  # @return [String, nil] Cleaned and truncated text or nil if blank
  def clean_and_truncate(text)
    return nil if text.blank?

    # Remove quotes if present
    cleaned = text.gsub(/^["']|["']$/, '').strip

    # Remove person names (simple heuristic: capitalized words)
    # This is a basic filter - may need refinement
    # cleaned = remove_person_names(cleaned)

    # For long sessions, don't truncate aggressively
    is_long_session = @time_session.duration && @time_session.duration > LONG_SESSION_THRESHOLD
    max_length = is_long_session ? MIN_LENGTH_FOR_LONG_SESSIONS : MAX_LENGTH

    # Allow 20% buffer for sentence completion
    flexible_max = (max_length * 1.2).to_i

    # Check if text ends with proper sentence ending
    ends_with_sentence = cleaned.match?(/[.!?]\s*\z/)

    # If text is within flexible limit AND ends properly, keep as-is
    return cleaned if cleaned.length <= flexible_max && ends_with_sentence

    # Text is too long OR doesn't end properly - find last complete sentence
    truncated = truncate_at_sentence_end(cleaned, flexible_max)

    # If we still couldn't find a good sentence boundary, fall back to hard truncate
    # This should be rare if the AI follows instructions
    # Only fall back if result is blank or extremely short (< 50 chars)
    if truncated.blank? || truncated.length < 50
      Rails.logger.warn("CustomerDescriptionGenerator: Could not find sentence boundary for TimeSession #{@time_session.id}, using hard truncate")
      cleaned.truncate(max_length, omission: '...')
    else
      truncated
    end
  end

  # Truncate text at the last complete sentence within max_length
  # Recognizes sentence endings: . ! ?
  # Avoids truncating at abbreviations like "z.B." or "etc."
  #
  # @param text [String] Text to truncate
  # @param max_length [Integer] Maximum length
  # @param force_sentence_end [Boolean] If true, always truncates at last sentence even if text is shorter than max_length
  # @return [String, nil] Truncated text or nil if no sentence boundary found
  def truncate_at_sentence_end(text, max_length, force_sentence_end: false)
    # Find all sentence endings (., !, ?) within the text or max_length
    # Use regex to find sentence endings followed by space or end of string
    sentence_pattern = /[.!?](?=\s|$)/

    # Determine search space
    search_text = if force_sentence_end || text.length > max_length
                    text[0...max_length]
                  else
                    text
                  end

    # If text is within limit and ends properly, keep as-is (unless forced)
    return text if !force_sentence_end && text.length <= max_length && text.match?(/[.!?]\s*\z/)

    # Find all sentence ending positions
    matches = search_text.to_enum(:scan, sentence_pattern).map { Regexp.last_match.begin(0) }

    return nil if matches.empty?

    # Get the position of the last sentence ending
    last_sentence_end = matches.last

    # Extract text up to and including the sentence ending character
    truncated = text[0..last_sentence_end].strip

    # Abbreviation protection: only skip if the result is VERY short (< 30% of original text length)
    # and we have alternatives
    original_length = text.length < max_length ? text.length : max_length
    if truncated.length < (original_length * 0.3).to_i && matches.length > 1
      previous_sentence_end = matches[-2]
      truncated = text[0..previous_sentence_end].strip
    end

    truncated
  end

  # Remove likely person names from text
  # This is a heuristic approach - may need improvement
  #
  # @param text [String] Input text
  # @return [String] Text without names
  def remove_person_names(text)
    # Remove patterns like "Herr/Frau Name" or standalone capitalized words
    # that might be names (excluding first word and common words)
    text.gsub(/\b(Herr|Frau)\s+[A-ZÄÖÜ][a-zäöüß]+\b/, 'Mitarbeiter')
        .gsub(/\b[A-ZÄÖÜ][a-zäöüß]+\s+[A-ZÄÖÜ][a-zäöüß]+\b/, 'Mitarbeiter')
  end

  # Fallback to user description if generation fails
  #
  # @return [String] User description or default message
  def fallback_description
    @time_session.description.presence || 'Arbeiten am Projekt durchgeführt'
  end

  # Log API call for monitoring
  #
  # @param duration [Float] API call duration in seconds
  # @param response [Hash] OpenAI response
  def log_api_call(duration, result)
    usage = result[:token_usage] || {}
    Rails.logger.info(
      'CustomerDescriptionGenerator API call: ' \
      "time_session_id=#{@time_session.id} " \
      "duration_ms=#{(duration * 1000).round} " \
      "tokens=#{usage[:total_tokens]} " \
      "model=#{MODEL}"
    )
  end
end
