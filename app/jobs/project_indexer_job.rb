# frozen_string_literal: true

# Initial indexer for a connected ProjectRepository.
#
# Phase-1 coverage:
#   - Layer 4 (Project Vision) — M5
#   - Layer 3 (Capability Map) — M5
#   - Layer 1 (CodeSymbols via the parser gem) — M6
#
# Multi-repo policy: if a Project already has a Vision, Layer 4/3 generation
# is skipped for additional repos. Layer 1 runs per-repo regardless.
#
# Failure handling: on any rescue the ProjectIndex status flips to `failed`
# and the error message is persisted. The tmpdir is always cleaned up
# (GitCloner uses Dir.mktmpdir with block form).
class ProjectIndexerJob < ApplicationJob
  include Lalabase::Indexer::JobSupport

  queue_as :indexing

  # Layer 1 tuning constants — locked as contract.
  LAYER_1_BATCH_SIZE = 100 # symbols per OpenAI embeddings API call
  LAYER_1_PROGRESS_FILES = 10 # update layer_1_files_done every N files

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "ProjectIndexerJob: record not found — #{error.message}"
  end

  discard_on ActiveRecord::RecordNotFound do |_job, error|
    Rails.logger.warn "ProjectIndexerJob: repository deleted before perform — #{error.message}"
  end

  # trigger: who/what kicked off this full index — 'initial' (repo connect,
  # default), 'manual' (operator-triggered, future), or 'push' (a webhook with no
  # diffable baseline falls back to a full re-index). Logged in the run history.
  def perform(project_repository, trigger: 'initial')
    return unless code_indexing?(project_repository) # per-org operator gate (defensive: flag may flip after enqueue)
    return unless ai_enabled_or_settle_index!(project_repository) # GDPR opt-in: settles index as failed instead of deadlocking pending

    ActsAsTenant.with_tenant(project_repository.organisation) do
      repo = ProjectRepository.find(project_repository.id)
      index = ensure_index(repo)
      run_indexing(repo, index, trigger)
    end
  end

  private

  def ensure_index(repo)
    repo.project_index || ProjectIndex.create!(
      project_repository: repo,
      organisation: repo.organisation,
      status: 'pending'
    )
  rescue ActiveRecord::RecordNotUnique
    # Concurrent worker created the index between our existence-check and our
    # create — just re-load.
    repo.reload.project_index
  end

  def run_indexing(repo, index, trigger)
    started_at = Time.current
    index.update!(status: 'indexing', layer_4_status: 'indexing',
                  layer_3_status: 'indexing', layer_1_status: 'indexing',
                  error_message: nil)
    project = repo.project

    cloner = Lalabase::Indexer::GitCloner.new(repo)
    cloner.call do |path|
      scan = Lalabase::Indexer::RepoScanner.new(path).call
      generate_layer_4_and_3(project, repo.organisation, scan) if first_repo_for_project?(project)
      generate_layer_1(repo, index, path)
    end

    # last_indexed_commit FIX: without it EVERY first push webhook falls back to a
    # full reindex (RepoReindexJob can't diff against an empty base).
    index.update!(status: 'ready', layer_4_status: 'ready', layer_3_status: 'ready',
                  layer_1_status: 'ready', last_indexed_at: Time.current,
                  last_indexed_commit: cloner.cloned_commit)
    # Make it visible if the HEAD commit could NOT be captured (rev-parse
    # failed → nil): the index is 'ready', but the next push degrades again to a
    # full reindex for lack of a baseline. Silently this would be hard to
    # diagnose in operation.
    if cloner.cloned_commit.nil?
      Rails.logger.warn("ProjectIndexerJob: HEAD commit for repo #{repo.id} not captured — " \
                        'the next push falls back to a full re-index')
    end
    # Initial index finished → notify the connector (M9-5). Best-effort: the
    # notifier never raises, so it can't flip this success into the rescue below.
    Notifications::IndexOutcomeNotifier.call(repository: repo, outcome: :completed)

    # For a full index, symbols_added is the total symbol count AFTER the run. The
    # full index replaces ALL symbols (delete_all + insert), so "after the
    # run" == "added in this run". For an incremental reindex the same column
    # carries a real delta (only the changed ones) — so the meaning of
    # symbols_added is run-type-dependent (incremental? distinguishes them).
    record_index_run(repo: repo, trigger: trigger, status: 'ready', started_at: started_at,
                     incremental: false, commit_sha: cloner.cloned_commit,
                     files_count: index.layer_1_files_total, symbols_added: repo.code_symbols.count,
                     triggered_by_user_id: triggerer_id(repo, trigger))
  rescue StandardError => e
    record_index_run(repo: repo, trigger: trigger, status: 'failed', started_at: started_at,
                     incremental: false, error: e, triggered_by_user_id: triggerer_id(repo, trigger))
    fail_index!(index, repo, e)
  end

  # Who triggered this run: the connector for the initial index, nobody for a
  # push (GitHub). A future manual trigger would carry its own user.
  def triggerer_id(repo, trigger)
    trigger == 'initial' ? repo.connected_by_user_id : nil
  end

  # Per the multi-repo decision: only the first repo connect triggers Layer 4/3.
  def first_repo_for_project?(project)
    !ProjectLayer4Vision.exists?(project_id: project.id)
  end

  def generate_layer_4_and_3(project, organisation, scan)
    # The CHAT half of :repository_indexing (KI-Pakete P3). `lane:` is mandatory
    # here because the row spans both lanes — this line builds the chat provider,
    # the next one the embedding provider, and they route independently.
    #
    # The row is utility: the vision and the capability texts are indexing
    # scaffolding read by the RAG pipeline, generated over a whole repository at
    # once, so a curated org runs them on its package's cheapest rung.
    chat_provider  = Lalabase::Llm::Factory.for_feature(:repository_indexing, organisation, lane: :chat)
    embed_provider = embedding_provider(organisation)

    persist_vision(project, organisation, chat_provider, embed_provider, scan)
    persist_capabilities(project, organisation, chat_provider, embed_provider, scan)
  end

  def persist_vision(project, organisation, chat_provider, embed_provider, scan)
    result = Lalabase::Indexer::VisionGenerator.new(provider: chat_provider, scan: scan).call
    embedding = embed_provider.embed(text: result[:content])

    # Vision + its sidecar row (triple + source_hash) in ONE transaction (m1). The
    # rescue below stays OUTSIDE it, so a Vision unique conflict rolls BOTH back
    # (idempotent skip).
    ActiveRecord::Base.transaction do
      vision = ProjectLayer4Vision.create!(
        project: project,
        organisation: organisation,
        content: result[:content],
        language: result[:language],
        auto_generated: true
      )
      ContentEmbedding.create!(
        organisation: organisation,
        embeddable: vision,
        **Lalabase::Indexer::EmbeddingColumns.from(embed_provider),
        embedding: embedding,
        source_hash: ContentEmbedding.source_hash_for(result[:content]),
        indexed: true, embedded_at: Time.current
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent job already created the Vision for this project — treat as
    # success and move on (idempotent at the project level). By construction this
    # can only be the VISION's unique index: the sidecar row references the fresh
    # Vision UUID, so its triple row can never pre-exist.
    Rails.logger.info "ProjectIndexerJob: Vision already exists for project #{project.id}, skipping"
  end

  def persist_capabilities(project, organisation, chat_provider, embed_provider, scan)
    result = Lalabase::Indexer::CapabilityGenerator.new(provider: chat_provider, scan: scan).call
    # Dedupe case-insensitively. The PG unique index on (project_id, name) is
    # case-sensitive, so without downcasing here an LLM that returns both
    # "Notifications" and "notifications" would silently create two semantic
    # duplicates side by side.
    unique_capabilities = result[:capabilities].uniq { |cap| cap[:name].to_s.downcase }
    unique_capabilities.each do |cap|
      embedding = embed_provider.embed(text: cap[:description])
      # Capability + its sidecar row (triple + source_hash) in ONE transaction (m1);
      # the per-iteration rescue stays OUTSIDE it so a name conflict rolls BOTH back
      # and skips.
      ActiveRecord::Base.transaction do
        capability = ProjectCapability.create!(
          project: project,
          organisation: organisation,
          name: cap[:name],
          description: cap[:description],
          key_modules: cap[:key_modules],
          auto_generated: true
        )
        ContentEmbedding.create!(
          organisation: organisation,
          embeddable: capability,
          **Lalabase::Indexer::EmbeddingColumns.from(embed_provider),
          embedding: embedding,
          source_hash: ContentEmbedding.source_hash_for(cap[:description]),
          indexed: true, embedded_at: Time.current
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent job persisted a capability with the same name first. By
      # construction only the CAPABILITY's (project_id, name) index can conflict:
      # the sidecar references the fresh Capability UUID, so its triple can't pre-exist.
      Rails.logger.info "ProjectIndexerJob: Capability #{cap[:name]} already exists for project #{project.id}, skipping"
    end
  end

  # ------------------------------------------------------------------ Layer 1 --

  def generate_layer_1(repo, index, repo_path)
    walker = Lalabase::Indexer::Symbols::Walker.new(repo_path)
    total = walker.file_count
    index.update!(layer_1_files_total: total, layer_1_files_done: 0)

    embed_provider = embedding_provider(repo.organisation)

    # Atomicity: delete_all + insert_all in one transaction so a mid-flight
    # embed_batch failure rolls back to the previous symbol set. Without this,
    # a transient OpenAI 5xx would wipe the user's index and leave it empty
    # until the next successful re-run.
    CodeSymbol.transaction do
      # Source-of-truth model: each Layer-1 run replaces the prior set for THIS
      # repo. delete_all inside the transaction ensures the swap is atomic.
      # Sidecar purge (embedding v2 PR 2): the CodeSymbol delete_all is callback-free,
      # so purge the matching content_embeddings rows first (subselect over the same
      # scope) — otherwise a full index would leak orphan sidecar rows on every push.
      ContentEmbedding.purge_for(embeddable_type: 'CodeSymbol',
                                 embeddable_ids: CodeSymbol.where(project_repository_id: repo.id).select(:id))
      CodeSymbol.where(project_repository_id: repo.id).delete_all

      pending_symbols = []
      files_done = 0

      walker.each_file_symbols do |symbols, _rel_path|
        pending_symbols.concat(symbols)
        files_done += 1

        # Flush in batches to keep memory bounded. Shared persistence logic lives
        # in Indexer::SymbolPersistence (also used by RepoReindexJob).
        Lalabase::Indexer::SymbolPersistence.persist(repo:, embed_provider:, symbols: pending_symbols.shift(LAYER_1_BATCH_SIZE)) while pending_symbols.size >= LAYER_1_BATCH_SIZE

        index.update_columns(layer_1_files_done: files_done) if (files_done % LAYER_1_PROGRESS_FILES).zero?
      end

      Lalabase::Indexer::SymbolPersistence.persist(repo:, embed_provider:, symbols: pending_symbols) if pending_symbols.any?
      index.update_columns(layer_1_files_done: files_done)
    end
  end
end
