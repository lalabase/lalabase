# frozen_string_literal: true

# app/services/actors/create_ai_post.rb
#
# Tier-2 actor: owns #call because the LLM round-trip (seconds) must NOT hang in a
# DB transaction — same reason SaveTicket is Tier 2. It reuses the shared BaseActor
# helpers (with_error_mapping / with_actor_context / success / failure).
#
# The "Ask AI" side path of posts#create used to live inline in the controller
# (~85 lines): build the prompt from the ticket, its conversation and ALL project
# notes, call the gated LLM seam, meter usage, then write an answer post as the
# GLOBAL is_ai user. Its six rescue branches become coded ActorErrors the controller
# maps back to the SAME flash copy (no new locale keys). The LLM call sits OUTSIDE
# any transaction; only the answer-post write is wrapped in a small transaction.
#
# Failure is "continue without an AI post": this actor runs AFTER the user's own
# post has already been committed by PostUpdateService, so a refused/failed AI reply
# never touches the user's post (F1, synchronous like before).
module Actors
  class CreateAiPost < BaseActor
    # NO provider and NO model constant on purpose (S2 of
    # doc/ki_provider_reichweite_plan.md): both are resolved from the org's chat
    # choice — the provider by Factory.for_feature(:ask_ai_post, org) since R6, the model by the factory
    # precedence (org.preferred_chat_model > credential.default_model > provider
    # constant). A literal 'gpt-4o-mini' would be a runtime 404 on a
    # Mistral/IONOS endpoint. PROVIDER_OPTIONS is gone for the same reason one
    # status code up: it is merged VERBATIM into the vendor request, so the three
    # OpenAI knobs would have reached Anthropic / Gemini as unknown fields (400).
    # top_p: 1 and frequency_penalty: 0.0 were the OpenAI defaults (no-ops), and
    # presence_penalty's intent — do not repeat yourself — is spelled out twice in
    # #instructions below.
    # max_tokens/temperature stay: every provider maps them into its own dialect.
    MAX_TOKENS = 500
    TEMPERATURE = 0.7
    CALL_TYPE = 'ask_ai'

    def initialize(ticket:, current_user:, organisation:)
      super()
      @ticket = ticket
      @current_user = current_user
      @organisation = organisation
      @ai_post = nil
    end

    # The created AI post, or nil when the LLM returned no content.
    def record
      @ai_post
    end

    def call
      with_error_mapping do
        with_actor_context do
          content = generate_ai_reply
          create_ai_post(content) if content.present?
          success(@ai_post)
        end
      end
    end

    private

    # Runs the gated LLM call + usage metering OUTSIDE any transaction and maps every
    # provider failure to a coded ActorError (the controller turns the code back into
    # the existing flash copy). Errors NOT matched here (e.g. a raw Provider::Error)
    # fall through to BaseActor#with_error_mapping -> :internal_error, which the
    # controller renders as the generic ai_fallback — same as the old broad rescue.
    def generate_ai_reply
      # Route through the single gated seam, following the org's chat provider
      # (P4 of doc/ki_provider_reichweite_plan.md). The prompt carries the ticket,
      # its public conversation and, for a notes reader, the project notes, so the admin's provider
      # choice — which jurisdiction sees that — has to reach this call. A missing
      # credential surfaces as MissingCredentialError (mapped below), not nil.
      provider = Lalabase::Llm::Factory.for_feature(:ask_ai_post, @organisation)

      result = provider.chat(
        messages: [{ role: 'system', content: instructions }, { role: 'user', content: context }],
        max_tokens: MAX_TOKENS, temperature: TEMPERATURE
      )

      Lalabase::Llm::UsageTracking.record(
        organisation: @organisation, provider: provider,
        token_usage: result[:token_usage], model: result[:model_used], call_type: CALL_TYPE,
        action: Lalabase::Llm::ActionRegistry::POST_AI, subject: @ticket, user: @current_user
      )

      result[:content]
    rescue Lalabase::Llm::AiDisabledError
      # GDPR opt-in gate: org has not enabled AI features.
      raise ActorError.new("AI features are not enabled for organisation #{@organisation&.id}", code: :ai_disabled)
    rescue Lalabase::Llm::QuotaExceededError
      # Quota paused (BYOK / monthly reset). Ordered before the broad provider rescue.
      raise ActorError.new('AI quota exceeded', code: :quota_exceeded)
    rescue Lalabase::Llm::Factory::MissingCredentialError
      # No usable system credential (the old nil-client branch).
      Rails.logger.warn "AI service not configured for organisation #{@organisation&.id}"
      raise ActorError.new('AI service not configured', code: :not_configured)
    rescue Lalabase::Llm::Provider::AuthError => e
      # Provider maps the vendor 401 to AuthError.
      Rails.logger.error "AI API key invalid: #{e.message}"
      raise ActorError.new(e.message, code: :invalid_key)
    rescue Faraday::ClientError => e
      Rails.logger.error "AI API error: #{e.message}"
      raise ActorError.new(e.message, code: :provider_error)
    end

    def create_ai_post(content)
      # Global AI user — DELIBERATELY without tenant scope, since it is used across
      # orgs. No AI user configured is a failure (was a silent log before), so the
      # controller can surface the generic ai_fallback instead of quietly doing nothing.
      ai_user = User.where(is_ai: true).first
      raise ActorError.new('No AI user configured', code: :internal_error) unless ai_user

      ActiveRecord::Base.transaction do
        @ai_post = Post.create!(ticket: @ticket, user: ai_user, content: content)
      end
    end

    # Prompt text taken 1:1 from the former controller inline block (no tuning — that
    # is explicitly out of scope for the seam move), split in two on 27.09.2026: what
    # the ticket, its comments and the notes say travels as the user message, the
    # instructions as the system message, so text someone typed into a ticket cannot
    # speak with the voice of the instructions.
    #
    # The answer becomes a PUBLIC comment every reader of the ticket sees, so it reads
    # public comments only (not even those private to the asker) and the project notes
    # only when the asker may read notes.
    def context
      question = 'Das aktuelle Thema dieser Frage ist: '
      question += @ticket.content.to_plain_text
      question += 'Darauf folgt folgende Konversation: '

      # created_at, not find_each: the ids are random UUIDs and would shuffle the conversation
      @ticket.posts.public_posts.includes(:user).order(:created_at).each do |post|
        question += "#{post.user.full_name}: #{post.content.to_plain_text}\n"
      end

      return question unless may_read_notes?

      question += 'Wir haben folgende Informationen aus den Notes zu einem Projekt: '
      @ticket.project.notes.each_with_index do |note, index|
        question += "Informationschipsel #{index + 1} Anfang"
        question += "#{note.title} : #{note.description}  \n"
        question += "#{note.content.to_plain_text}\n"
        question += "Informationschipsel #{index + 1} Ende"
        question += "Sollte die Information 'Informationschipsel #{index + 1}' keinen inhaltlichen Bezug zu #{@ticket.content.to_plain_text} haben, ignoriere sie und beziehe die Information nicht mit ein.\n"
      end
      question
    end

    def instructions
      question = +'Beziehe alle Informationen aus den Notes mit ein wenn diese nicht ausdrücklich ignoriert werden sollen. Nutze für die Formatierung die HTML-Tags <strong>, <ul> und <li>.'
      question << 'Antworte in Stichworten und kurzen Phrasen.'
      question << 'Nicht genutzte Informationen sollen gar nicht erst erwähnt werden.'
      question << "Versuche doppelte Informationen in deiner Antwort zu vermeiden'."
      question << 'Wiederhole keine Informationen die bereits in den vorherigen Antworten erwähnt wurden.'
      question << 'Lasse die Anrede weg und setze direkt mit dem Text an.'
      question
    end

    def may_read_notes?
      Current.project_policy(@current_user, @ticket.project).area_access?(:notes, :read)
    end
  end
end
