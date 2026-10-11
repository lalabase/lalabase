# frozen_string_literal: true

class EmbeddingReprocessingService
  def initialize(organisation)
    @organisation = organisation
  end

  def call
    # GDPR opt-in gate: don't enqueue hundreds of jobs that would each just
    # skip — surface the disabled state to the caller (AI sync status UI reads
    # :error on failure, mirroring the rescue path below).
    unless @organisation.ai_enabled?
      return { success: false, total_jobs: 0,
               error: I18n.t('shared.ai.disabled_admin_hint') }
    end

    # Quota-aware catch-up (S3, test 30): if the org's embedding calls would be
    # metered AND its budget is already exhausted, don't enqueue a storm of jobs
    # that would each just pause — leave the rest pending until budget returns.
    # BYOK/non-quota orgs are unaffected (Gate.exhausted? is false for them).
    embedding_provider = Lalabase::Llm::Factory.embedding_provider_name(@organisation)
    if Lalabase::Llm::Gate.exhausted?(@organisation, embedding_provider, kind: :embedding)
      return { success: false, total_jobs: 0,
               error: I18n.t('services.embedding_reprocessing.quota_exhausted') }
    end

    ActsAsTenant.with_tenant(@organisation) do
      # The "what is still pending" rules live in ONE place (Embeddings::PendingEmbeddings)
      # so they can't drift from the monthly catch-up (Embeddings::PendingBacklog). Here
      # we run inside with_tenant, so each relation self-scopes to this org; the identical
      # enqueue-and-count loop stays factored into #enqueue_pending.
      total_jobs = Embeddings::PendingEmbeddings.relations_by_model.sum do |model, relation|
        enqueue_pending(relation, model)
      end

      Rails.logger.debug "EmbeddingReprocessingService: Queued #{total_jobs} jobs for organisation #{@organisation.id}"

      {
        success: true,
        total_jobs: total_jobs,
        message: I18n.t('services.embedding_reprocessing.jobs_started', count: total_jobs)
      }
    rescue StandardError => e
      Rails.logger.error "EmbeddingReprocessingService failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      {
        success: false,
        error: e.message,
        total_jobs: 0
      }
    end
  end

  private

  # Enqueue one EmbeddingProcessingJob per record in the relation and return the
  # count. Extracted because every content type repeated this identical loop — only
  # the pending relation and its record_class differ (kept explicit at the call
  # sites above). find_each batches so a large re-index does not load every row.
  def enqueue_pending(relation, record_class)
    count = 0
    relation.find_each do |record|
      EmbeddingProcessingJob.perform_later(
        record_class: record_class,
        record_id: record.id,
        fragment_association: :fragments
      )
      count += 1
    end
    count
  end
end
