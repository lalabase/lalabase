# frozen_string_literal: true

# Full re-sync of one DocumentationSet from its connected git repository.
#
# Deliberately a FULL resync (no incremental diffing) for v1: shallow-clone the
# repo via the existing GitCloner, read every .md under the set's path_prefix,
# upsert each page, and soft-remove pages whose source file vanished. A per-set
# advisory lock serialises runs and is released even if the job crashes mid-run.
#
# Failures are recorded on a DocumentationSyncRun with one of six distinguishable
# error classes (DT4) so the UI can show a specific, actionable message.
class DocumentationSyncJob < ApplicationJob
  queue_as :default

  ERROR_MESSAGE_LIMIT = 1000

  # Deeper than the indexer's depth-1 clone ON PURPOSE: the logbook (Slice 2)
  # is fed from `git log -- <path_prefix>`, and a shallow clone only carries as
  # much history as its depth. 100 matches GitLogReader::MAX_COMMITS — cloning
  # deeper would download history the logbook never shows.
  CLONE_DEPTH = 100

  # git strings are attacker-influenced repo content; keep them inside the
  # string columns instead of crashing the sync on an oversized subject.
  COMMIT_FIELD_LIMIT = 255

  # Which files count as documentation pages — single source of truth is the
  # renderer, which also uses it to detect internal links.
  MARKDOWN_EXTENSIONS = Documentation::MarkdownRenderer::MARKDOWN_EXTENSIONS

  # Git writes failure reasons to stderr in prose that varies by version and
  # host, so these are best-effort heuristics; anything unmatched falls back to
  # the generic 'repo_unreachable' (see #classify_clone_error).
  AUTH_PATTERNS = /authentication failed|could not read username|invalid username or password|403|permission denied/i
  NOT_FOUND_PATTERNS = /repository not found|not found|does not exist|could not read from remote|404/i

  # Raised for classified, expected sync failures (no retry — user must act).
  class SyncError < StandardError
    attr_reader :error_class

    def initialize(message, error_class:)
      @error_class = error_class
      super(message)
    end
  end

  # Shared context for a single run, threaded to the run-recording helpers.
  SyncContext = Struct.new(:set, :trigger, :user_id, :started_at, keyword_init: true)

  def perform(documentation_set_id, trigger: 'manual', triggered_by_user_id: nil)
    set = ActsAsTenant.without_tenant { DocumentationSet.find_by(id: documentation_set_id) }
    return if set.nil?

    ActsAsTenant.with_tenant(set.organisation) do
      return if skip_unchanged_poll?(set, trigger)

      with_sync_lock(set) do |acquired|
        next unless acquired # another sync already running for this set

        run_sync(set, trigger, triggered_by_user_id)
      end
    end
  end

  private

  # Polling cost guard: one ls-remote round-trip instead of a full depth-100
  # clone when the remote tip hasn't moved since the last successful sync.
  # Deliberately narrow:
  #   * polling only — a MANUAL sync always runs fully, so it stays the user's
  #     repair tool (re-render after a code change, heal a stuck state);
  #   * ready only — a failed set must retry even on an unchanged tip, the
  #     failure may have been transient (network, OOM mid-render);
  #   * nil from ls-remote (network hiccup) fails OPEN into the full sync.
  # A skipped poll records nothing: 48 no-op runs per day would drown the
  # logbook's sync-run history.
  def skip_unchanged_poll?(set, trigger)
    return false unless trigger == 'polling'
    return false unless set.ready? && set.last_synced_commit.present?

    remote_head = Lalabase::Indexer::GitCloner.new(set.project_repository).remote_head_commit
    remote_head.present? && remote_head == set.last_synced_commit
  end

  def run_sync(set, trigger, triggered_by_user_id)
    context = SyncContext.new(set: set, trigger: trigger, user_id: triggered_by_user_id, started_at: Time.current)
    stamp_set(set, sync_status: 'syncing')

    result = clone_and_upsert(set)

    stamp_set(set, sync_status: 'ready', last_synced_at: Time.current, last_synced_commit: result[:commit])
    record_run(context, status: 'ready', commit_sha: result[:commit],
                        pages_synced: result[:synced], pages_removed: result[:removed])
    # Chat-grounding ingestion (Slice 3): fan out embedding jobs only AFTER the
    # sync is recorded ready, and only for pages that actually changed this run.
    enqueue_embedding_jobs(result[:changed_page_ids])
  rescue SyncError => e
    fail_run(context, e.error_class, e.message)
  rescue StandardError => e
    fail_run(context, 'repo_unreachable', e.message)
    raise if Rails.env.local? # loud in dev/test, recorded failure in production
  end

  # Status stamps bypass validations ON PURPOSE: they are the job's own
  # bookkeeping and must succeed even when the row itself is invalid — e.g. a
  # path_prefix written past validations, the exact case the containment guard
  # rejects. With update! the RecordInvalid would fire BEFORE the failure could
  # be recorded, crashing the job instead of surfacing a clean failed run.
  def stamp_set(set, **attrs)
    set.update_columns(attrs.merge(updated_at: Time.current))
  end

  # Clones the repo and upserts every markdown page. Returns counts + commit +
  # the ids of the pages that actually changed (for the embedding fan-out).
  def clone_and_upsert(set)
    synced = 0
    seen_paths = []
    changed_page_ids = []
    commits = []
    # Preload every existing page once (keyed by path) to avoid a per-file query.
    existing_pages = set.documentation_pages.index_by(&:path)
    cloner = Lalabase::Indexer::GitCloner.new(set.project_repository, depth: CLONE_DEPTH)

    cloner.call do |repo_path|
      docs_dir = repo_path.join(set.path_prefix)
      # Containment guard (second defense layer; first is the model validation):
      # Pathname#join swaps the base for an absolute path_prefix ("/etc") and
      # keeps "../" segments, so a hostile or corrupted prefix could make this
      # job read markdown from OUTSIDE the cloned repo (e.g. a parallel clone
      # of another tenant in the same tmp parent). Never glob outside the clone.
      raise path_not_found_error(set) unless contained_in?(repo_path, docs_dir)
      raise path_not_found_error(set) unless docs_dir.directory?

      markdown_files(docs_dir).each do |file|
        relative = file.relative_path_from(docs_dir).to_s
        changed = upsert_page(set, existing_pages[relative], relative, file.read)
        changed_page_ids << changed.id if changed
        seen_paths << relative
        synced += 1
      end

      # Read inside the block (the clone dir is wiped afterwards); persist
      # outside, after the pages are settled.
      commits = read_commit_log(set, repo_path)
    end

    removed = mark_missing_removed(set, seen_paths)
    store_commits(set, commits)
    { synced: synced, removed: removed, commit: cloner.cloned_commit, changed_page_ids: changed_page_ids }
  rescue Lalabase::Indexer::GitCloner::Error => e
    raise SyncError.new(e.message, error_class: classify_clone_error(e))
  end

  # Best-effort ON PURPOSE: the pages are the product, the logbook is auxiliary
  # context. A git-log hiccup must not turn an otherwise successful sync into a
  # failed run — we log and move on with an empty logbook delta.
  def read_commit_log(set, repo_path)
    Documentation::GitLogReader.new(repo_path: repo_path, path_prefix: set.path_prefix).commits
  rescue Documentation::GitLogReader::Error => e
    Rails.logger.warn("DocumentationSyncJob: logbook skipped for set #{set.id} — #{e.message}")
    []
  end

  # Append-only logbook: only SHAs the set has not seen yet are inserted.
  # Standalone create! (not via the association) for the same autosave reason
  # as upsert_page above.
  def store_commits(set, commits)
    return if commits.empty?

    known = set.documentation_commits.where(commit_sha: commits.map(&:sha)).pluck(:commit_sha).to_set

    commits.each do |commit|
      next if known.include?(commit.sha)

      DocumentationCommit.create!(
        documentation_set: set,
        organisation: set.organisation,
        commit_sha: commit.sha,
        author_name: commit.author_name&.truncate(COMMIT_FIELD_LIMIT),
        committed_at: commit.committed_at,
        message: commit.message&.truncate(COMMIT_FIELD_LIMIT)
      )
    end
  end

  # Upserts one page. Returns the page WHEN it changed (created, content updated,
  # or revived from removed) so the caller can enqueue its embedding; returns nil
  # for the unchanged skip, which enqueues nothing.
  def upsert_page(set, existing_page, relative_path, content)
    blob_sha = git_blob_sha(content)
    # Build the new page standalone (NOT via set.documentation_pages.build): if a
    # later page fails to render mid-loop, a half-built page must not sit in the
    # set's in-memory association, or the failure path's set.update!(sync_status:)
    # would try to autosave that invalid page and raise instead of recording the
    # failure cleanly.
    page = existing_page || DocumentationPage.new(documentation_set: set, path: relative_path)

    # Unchanged and still present → nothing to do (cheap incremental skip).
    return nil if page.persisted? && page.git_blob_sha == blob_sha && page.removed_at.nil?

    rendered = render_page(set, relative_path, content)
    page.assign_attributes(
      # Reuse the already-loaded tenant so the belongs_to presence check on save
      # does not re-query organisations per page.
      organisation: set.organisation,
      title: extract_title(content, relative_path),
      markdown_body: content,
      rendered_html: rendered.html,
      git_blob_sha: blob_sha,
      removed_at: nil
    )
    page.save!
    # Rebuild the page's outgoing knowledge links (Slice 4) from the targets the
    # renderer just resolved. Reached ONLY on a changed page — the blob-SHA skip
    # above returns nil for an unchanged one, so its references are left untouched.
    rebuild_references(page, rendered.references)
    page
  end

  # Mirror of Note#rebuild_wiki_references: delete + insert keeps a page's outgoing
  # link index in lock-step with its current content, and stays correct when a link
  # is added, removed or repointed between syncs. The renderer already deduped the
  # targets; the (source, target) unique index is the second line of defense.
  def rebuild_references(page, targets)
    page.outgoing_references.delete_all
    targets.each do |target|
      page.outgoing_references.create!(
        organisation: page.organisation,
        target: target,
        # A display label only (the backlink tombstone) — truncate so an over-long
        # target title can never fail the sync; the column caps at 255.
        target_title_snapshot: target.try(:title)&.truncate(255)
      )
    end
  end

  # Enqueue an embedding job per changed page. Pages are already committed here
  # (each save! ran in its own transaction, and there is no wrapping one), so a
  # plain perform_later is effectively after-commit — the job re-reads the page
  # and runs the SHARED EmbeddingProcessingService, exactly like the note/ticket
  # actors do.
  #
  # Best-effort ON PURPOSE (same contract as the logbook, read_commit_log): the sync
  # is already recorded ready by the time we get here, so a queue hiccup must NOT flip
  # a successful sync to failed (which would also record a spurious second run). The
  # pages are persisted with embeddings_creation_flag = nil, so a missed enqueue is
  # healed by the next content change or an org-wide re-index.
  def enqueue_embedding_jobs(page_ids)
    page_ids.each do |page_id|
      EmbeddingProcessingJob.perform_later(
        record_class: DocumentationPage,
        record_id: page_id,
        fragment_association: :fragments
      )
    end
  rescue StandardError => e
    Rails.logger.warn("DocumentationSyncJob: embedding fan-out skipped for set #{page_ids.inspect} — #{e.message}")
  end

  # Renders the page AND collects the knowledge targets its lalabase:// links
  # resolved to (one pass, no second parse). Returns the renderer's Result
  # (html + references).
  def render_page(set, relative_path, content)
    Documentation::MarkdownRenderer.new(documentation_set: set, page_path: relative_path).render_with_references(content)
  rescue StandardError => e
    raise SyncError.new("failed to render '#{relative_path}': #{e.message}", error_class: 'markdown_invalid')
  end

  def markdown_files(docs_dir)
    Dir.glob(docs_dir.join('**', '*'))
       .map { |p| Pathname.new(p) }
       .select { |p| p.file? && MARKDOWN_EXTENSIONS.include?(p.extname.downcase) }
       .sort
  end

  def path_not_found_error(set)
    SyncError.new("docs path '#{set.path_prefix}' not found in repository", error_class: 'path_not_found')
  end

  # True when dir is repo_root itself ("." prefix = docs at repo root) or a
  # descendant of it after resolving "../" and absolute segments.
  def contained_in?(repo_root, dir)
    root = repo_root.expand_path.to_s
    resolved = dir.expand_path.to_s
    resolved == root || resolved.start_with?("#{root}/")
  end

  # Soft-remove pages whose source file is no longer present in the repo. Bulk
  # update by design — there are no per-row callbacks to run on removal.
  #
  # But the pages DO own polymorphic embedding fragments (Slice 3) AND outgoing
  # references (Slice 4), and update_all skips both dependent hooks — so we purge
  # them explicitly first, or a doc whose source file vanished would keep grounding
  # the chat and keep a stale link row. Ids are plucked up front so the purges and
  # the flip target exactly the same rows. (A file that later reappears re-renders —
  # its removed_at is non-nil, so the blob-SHA skip does not apply — and rebuilds.)
  def mark_missing_removed(set, seen_paths)
    missing_ids = set.documentation_pages.where.not(path: seen_paths).where(removed_at: nil).pluck(:id)
    return 0 if missing_ids.empty?

    DocumentationPage.purge_fragments_for(missing_ids)
    DocumentationPage.purge_references_for(missing_ids)
    set.documentation_pages.where(id: missing_ids)
       .update_all(removed_at: Time.current, updated_at: Time.current)
    missing_ids.size
  end

  # Git blob SHA of the file content (matches `git hash-object`), computed in
  # Ruby so no per-file shell-out is needed.
  def git_blob_sha(content)
    bytes = content.to_s.b
    header = "blob #{bytes.bytesize}\0".b
    Digest::SHA1.hexdigest(header + bytes)
  end

  def extract_title(content, relative_path)
    heading = content.to_s.lines.find { |line| line.start_with?('# ') }
    return heading.sub(/\A#\s+/, '').strip if heading

    Documentation::Naming.humanize(File.basename(relative_path, File.extname(relative_path)))
  end

  def classify_clone_error(error)
    message = error.message.to_s
    return 'auth' if message.match?(AUTH_PATTERNS)
    return 'source_deleted' if message.match?(NOT_FOUND_PATTERNS)

    'repo_unreachable'
  end

  # Serialise sync runs for one set with a PostgreSQL advisory lock.
  #
  # Session-scoped (pg_try_advisory_lock), NOT transaction-scoped: the run does a
  # network git clone that can take many seconds, and we must not hold a database
  # transaction open across that. We release it explicitly in `ensure`; if the
  # worker is hard-killed before that runs, Postgres frees the lock when the
  # connection closes, so it can never leak permanently. The lock id is an
  # integer (crc32), so interpolating it into SQL is injection-safe.
  def with_sync_lock(set)
    lock_id = Zlib.crc32("documentation_sync:#{set.id}")
    connection = ActiveRecord::Base.connection
    acquired = connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})")

    begin
      yield(acquired)
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{lock_id})") if acquired
    end
  end

  # Writes the append-only run record. `context` carries the fields common to
  # every run (set, trigger, user, timing); `attrs` are the outcome-specific
  # columns the caller sets (status + either the success counts or the error).
  def record_run(context, **attrs)
    DocumentationSyncRun.create!({
      organisation: context.set.organisation,
      documentation_set: context.set,
      trigger: context.trigger,
      triggered_by_user_id: context.user_id,
      started_at: context.started_at,
      finished_at: Time.current
    }.merge(attrs))
  end

  def fail_run(context, error_class, message)
    stamp_set(context.set, sync_status: 'failed')
    record_run(context, status: 'failed', error_class: error_class,
                        error_message: message&.truncate(ERROR_MESSAGE_LIMIT))
  end
end
