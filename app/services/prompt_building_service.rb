# frozen_string_literal: true

# app/services/prompt_building_service.rb

class PromptBuildingService
  # Size of the retrieved context window (was an inline magic number).
  RELEVANT_FRAGMENTS_LIMIT = 15

  def initialize(question, organisation)
    @question = question
    @organisation = organisation
  end

  def call
    # Generate the embedding of the question via the org's embedding provider.
    question_embedding = Lalabase::QueryEmbedding.embed(@question, @organisation)

    # Retrieve the most similar text fragments — org-wide, through the ONE read seam
    # over the content_embeddings sidecar (embedding v2 PR 4b).
    hits = Embeddings::NearestNeighbors.call(
      embeddable_type: 'Fragment', organisation: @organisation,
      query_vector: question_embedding, limit: RELEVANT_FRAGMENTS_LIMIT
    )

    # Build the context
    context = hits.map { |hit| hit.record.plain_text_content }.join("\n\n")

    # Build the prompt for ChatGPT
    <<~PROMPT
      Du bist ein hilfreicher Assistent. Berücksichtige die folgenden Informationen, um die Frage des Benutzers zu beantworten:

      Kontext:
      #{context}

      Frage:
      #{@question}

      Antwort:
    PROMPT
  rescue StandardError => e
    # Any embedding/provider failure (auth, rate limit, missing credential, …)
    # degrades gracefully to a context-free prompt instead of failing the chat.
    Rails.logger.warn "Could not generate embeddings, falling back to simple prompt: #{e.message}"

    # Fallback: simple prompt without context
    <<~PROMPT
      Du bist ein hilfreicher Assistent. Beantworte die folgende Frage so gut wie möglich:

      Frage:
      #{@question}

      Antwort:
    PROMPT
  end
end
