# frozen_string_literal: true

# Incremental re-index triggered by a GitHub push webhook (Webhooks::Repositories
# Controller). Re-extracts Layer-1 symbols for ONLY the files a push changed —
# delete + re-insert per touched path — instead of re-walking and re-embedding
# the whole repo.
#
# Layer 4 (Vision) / Layer 3 (Capabilities) are deliberately NOT regenerated on
# push (plan decision D1): they change slowly and each costs LLM calls; a full
# re-index (ProjectIndexerJob) can refresh them on demand.
#
# Falls back to a full ProjectIndexerJob when there is no prior commit to diff
# against, or when the change set exceeds the GitHub Compare cap, or the Compare
# API errors.
class RepoReindexJob < ApplicationJob
  include Lalabase::Indexer::JobSupport

  queue_as :indexing

  # GitHub's Compare API returns at most 300 files and gives no "truncated"
  # flag. At or above this count the diff may be silently incomplete, so we
  # re-index the whole repo instead of indexing a partial change set.
  MAX_INCREMENTAL_FILES = 300

  # after_sha comes from the untrusted webhook payload and flows into git CLI args
  # (GitCloner ref:) and the Compare API URL. A git object name is hex-only, so a
  # matching value can never be read as a git option (argument injection). 7-64
  # chars covers abbreviated and full SHA-1 (40) / SHA-256 (64) names.
  COMMIT_SHA_PATTERN = /\A[0-9a-f]{7,64}\z/

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "RepoReindexJob: record not found — #{error.message}"
  end

  discard_on ActiveRecord::RecordNotFound do |_job, error|
    Rails.logger.warn "RepoReindexJob: repository deleted before perform — #{error.message}"
  end

  # after_sha:            pushed commit (webhook) or nil for a manual trigger, which
  #                       resolves the branch head itself.
  # trigger:              'push' (webhook) or 'manual' (user-initiated) — recorded in
  #                       the run history and carried through a full-index fallback.
  # triggered_by_user_id: the user who clicked "reindex now" (nil for a push).
  def perform(project_repository, after_sha: nil, trigger: 'push', triggered_by_user_id: nil)
    return unless code_indexing?(project_repository) # per-org operator gate (webhooks bypass Pundit)
    return unless ai_enabled_or_settle_index!(project_repository) # GDPR opt-in: settles index as failed instead of deadlocking pending

    ActsAsTenant.with_tenant(project_repository.organisation) do
      repo  = ProjectRepository.find(project_repository.id)
      index = repo.project_index

      # A push carries the commit SHA in its payload; a manual "reindex now" does
      # not, so resolve the branch head via the API. On failure resolve_head_sha
      # records a clear failure and returns nil — we STOP rather than clone into the
      # same wall (a bad token / lost access fails the clone too, only cryptically).
      if after_sha.blank?
        after_sha = resolve_head_sha(repo, index, triggered_by_user_id)
        return if after_sha.nil?
      end

      # Anomalous after_sha (not a hex object name) → safe full re-index instead of
      # feeding a possibly option-shaped ref into git. HMAC already authenticates the
      # sender; this is defense-in-depth on top of Open3's arg separation.
      return full_reindex(repo, trigger) unless valid_commit_sha?(after_sha)

      # No baseline commit to diff against → full index.
      return full_reindex(repo, trigger) if index.nil? || index.last_indexed_commit.blank?

      changed = fetch_changed_files(repo, index.last_indexed_commit, after_sha)
      return full_reindex(repo, trigger) if changed.nil?

      # Nothing changed between base and head → just advance the baseline. A manual
      # trigger still records a run so the click leaves a visible trace in the
      # history even when there was nothing to do; a push stays silent (a no-op
      # push would only be noise).
      if changed.empty?
        index.update!(last_indexed_commit: after_sha)
        record_noop_run(repo, after_sha, triggered_by_user_id) if trigger == 'manual'
        return
      end

      reindex(repo, index, after_sha, changed, trigger, triggered_by_user_id)
    end
  end

  private

  def valid_commit_sha?(sha)
    sha.to_s.match?(COMMIT_SHA_PATTERN)
  end

  # Delegate to a full re-index, preserving the original trigger so the run history
  # still distinguishes a push fallback from a manual one. The triggering user is
  # deliberately NOT threaded through: ProjectIndexerJob attributes full runs to the
  # connector (initial) or nobody, and a manual full fallback is a rare edge (no
  # baseline commit / head-resolve failure) — not worth widening that job's contract.
  def full_reindex(repo, trigger)
    ProjectIndexerJob.perform_later(repo, trigger: trigger)
  end

  # Resolve the connected repo's default-branch HEAD for a manual reindex (no push
  # payload SHA). On ANY GitHub error there is nothing to index: record a clear
  # failure (a bad/expired token or lost access gets an actionable message via
  # index_error_message) and return nil so #perform stops. Deliberately NOT a
  # full-clone fallback — if we couldn't even read HEAD, the clone hits the same
  # wall and buries the real cause under a git exit code.
  def resolve_head_sha(repo, index, triggered_by_user_id)
    client = Lalabase::Github::Client.new(token: repo.access_token)
    client.latest_commit_sha(full_name: repo.full_name, branch: repo.default_branch)
  rescue Lalabase::Github::Client::Error => e
    Rails.logger.warn "RepoReindexJob: manual head resolve failed for repo #{repo.id} (#{e.class})"
    record_manual_failure(repo, index, e, triggered_by_user_id)
    nil
  end

  # Records a manual-reindex failure across all three surfaces (index badge, run
  # history, connector notification) WITHOUT re-raising: the click failed, the user
  # sees why and can act (update the token / retry), and the job does not retry-loop
  # on a persistent auth error.
  def record_manual_failure(repo, index, error, triggered_by_user_id)
    index&.update!(status: 'failed', error_message: index_error_message(error, repo))
    record_index_run(repo: repo, trigger: 'manual', status: 'failed', started_at: Time.current,
                     incremental: true, error: error, triggered_by_user_id: triggered_by_user_id)
    Notifications::IndexOutcomeNotifier.call(repository: repo, outcome: :failed)
  end

  # History row for a manual reindex that found nothing to do (base == head): 0
  # files, ready, incremental. Without it a manual click on an already-current repo
  # would leave no trace and read as "nothing happened".
  def record_noop_run(repo, after_sha, triggered_by_user_id)
    record_index_run(repo: repo, trigger: 'manual', status: 'ready', started_at: Time.current,
                     incremental: true, commit_sha: after_sha, files_count: 0,
                     triggered_by_user_id: triggered_by_user_id)
  end

  # @return [Array<Hash>, nil] changed files, or nil to signal "do a full re-index"
  def fetch_changed_files(repo, base, head)
    client = Lalabase::Github::Client.new(token: repo.access_token)
    files = client.changed_files(full_name: repo.full_name, base: base, head: head)
    # >= the cap (not just >): GitHub never returns more than 300, so hitting
    # exactly 300 most likely means the list was truncated. See MAX_INCREMENTAL_FILES.
    return nil if files.size >= MAX_INCREMENTAL_FILES

    files
  rescue Lalabase::Github::Client::Error => e
    Rails.logger.warn "RepoReindexJob: compare failed for repo #{repo.id} (#{e.class}: #{e.message}) → full reindex"
    nil
  end

  # rubocop:disable Metrics/ParameterLists -- one indexing run has this many
  # independent inputs; a params object would only obscure them (same call
  # convention as JobSupport#record_index_run).
  def reindex(repo, index, after_sha, changed, trigger, triggered_by_user_id)
    started_at = Time.current
    index.update!(status: 'stale', layer_1_status: 'indexing', error_message: nil)

    # `removed` files are cleared but not re-inserted (balanced-swap note below);
    # count them separately so the run history shows the real delta.
    removed_count = changed.count { |c| c[:status] == 'removed' }
    added_count = 0

    # ref: after_sha — index the exact pushed commit, not just default-branch
    # HEAD (which can have moved on under rapid pushes). See GitCloner ref: docs.
    Lalabase::Indexer::GitCloner.new(repo, ref: after_sha).call do |path|
      walker = Lalabase::Indexer::Symbols::Walker.new(path)

      # Extract symbols for the changed files HERE — these are filesystem reads,
      # and they must stay OUTSIDE the transaction below so we never hold a row
      # lock during disk I/O. Keep `clear_paths`/`new_symbols` computation above
      # the `transaction` block; only DB ops belong inside it.
      #
      # Balanced swap invariant: every non-removed changed path is in BOTH
      # clear_paths (purged) and new_symbols (re-inserted), so the per-file
      # replace is exactly balanced — `removed` files are cleared but not
      # re-inserted. Keep these two lines in sync: widening the reject without
      # also adjusting clear_paths would leave stale symbols behind.
      clear_paths = paths_to_clear(changed)
      new_symbols = changed.reject { |c| c[:status] == 'removed' }
                           .flat_map { |c| walker.symbols_for(c[:filename]) }
      added_count = new_symbols.size

      # Atomic per-repo swap: purge the touched paths' old symbols and insert the
      # freshly extracted ones together, so a mid-flight embed failure rolls back
      # to the previous symbol set instead of leaving a half-updated index.
      CodeSymbol.transaction do
        # Sidecar purge (embedding v2 PR 2): the per-file delete_all is callback-free,
        # so purge the matching content_embeddings rows first (same file_path scope).
        ContentEmbedding.purge_for(
          embeddable_type: 'CodeSymbol',
          embeddable_ids: CodeSymbol.where(project_repository_id: repo.id, file_path: clear_paths).select(:id)
        )
        CodeSymbol.where(project_repository_id: repo.id, file_path: clear_paths).delete_all
        Lalabase::Indexer::SymbolPersistence.persist(repo: repo, embed_provider: embedding_provider(repo.organisation), symbols: new_symbols)
      end
    end

    index.update!(status: 'ready', layer_1_status: 'ready',
                  last_indexed_at: Time.current, last_indexed_commit: after_sha)

    record_index_run(repo: repo, trigger: trigger, status: 'ready', started_at: started_at,
                     incremental: true, commit_sha: after_sha, files_count: changed.size,
                     symbols_added: added_count, symbols_removed: removed_count,
                     triggered_by_user_id: triggered_by_user_id)
  rescue StandardError => e
    record_index_run(repo: repo, trigger: trigger, status: 'failed', started_at: started_at,
                     incremental: true, commit_sha: after_sha, error: e,
                     triggered_by_user_id: triggered_by_user_id)
    fail_index!(index, repo, e)
  end
  # rubocop:enable Metrics/ParameterLists

  # Paths whose existing symbols must be purged before re-inserting. Includes
  # previous_filename so a RENAME also clears the file's OLD path. GitHub sends
  # previous_filename for renamed/copied entries; `.compact` drops it when absent
  # — worst case the old path's symbols linger until that path is touched again,
  # which is acceptable (no wrong data, just a stale extra entry).
  def paths_to_clear(changed)
    changed.flat_map { |c| [c[:filename], c[:previous_filename]] }.compact.uniq
  end
end
