# frozen_string_literal: true

require 'rails_helper'

# What: DocumentationSyncJob — full resync, soft-removal, error taxonomy, and
#       the critical advisory-lock release on a mid-run crash (T5/D9).
# Type: Job spec.
# Why:  A leaked advisory lock deadlocks all future syncs of a set; the lock
#       MUST be released even when the job crashes. Also proves the six-class
#       failure taxonomy and that vanished source files stop surfacing.
RSpec.describe DocumentationSyncJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:set) { create(:documentation_set, project: project, path_prefix: 'docs/') }

  before { ActsAsTenant.current_tenant = organisation }

  after { @clone_dirs&.each { |d| FileUtils.remove_entry(d, true) } }

  # Materialises a fake cloned repo on disk (files keyed by repo-relative path)
  # and stubs GitCloner to yield it. remote_head defaults to nil (= ls-remote
  # unknown), which fails open into the full sync path. Returns the cloner
  # double for have_received assertions.
  def stub_cloner_with(files:, commit: 'commit-sha-1', remote_head: nil)
    dir = Dir.mktmpdir('doc-sync-spec-')
    (@clone_dirs ||= []) << dir
    files.each do |rel, content|
      full = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    cloner = instance_double(Lalabase::Indexer::GitCloner,
                             cloned_commit: commit, remote_head_commit: remote_head)
    allow(cloner).to receive(:call).and_yield(Pathname.new(dir))
    allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
    cloner
  end

  def stub_cloner_raising(error)
    cloner = instance_double(Lalabase::Indexer::GitCloner, cloned_commit: nil, remote_head_commit: nil)
    allow(cloner).to receive(:call).and_raise(error)
    allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
  end

  describe 'happy path' do
    it 'upserts a page per markdown file and marks the set ready' do
      stub_cloner_with(files: {
                         'docs/intro.md' => "# Intro\n\nHello.",
                         'docs/guide/setup.md' => "# Setup\n\nSteps."
                       })

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('ready')
      expect(set.last_synced_commit).to eq('commit-sha-1')
      expect(set.documentation_pages.pluck(:path)).to contain_exactly('intro.md', 'guide/setup.md')
      expect(set.documentation_pages.find_by(path: 'intro.md').title).to eq('Intro')
    end

    it 'records a ready sync run with page counts' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })

      expect { described_class.perform_now(set.id) }.to change(DocumentationSyncRun, :count).by(1)

      run = set.documentation_sync_runs.recent.first
      expect(run.status).to eq('ready')
      expect(run.pages_synced).to eq(1)
      expect(run.error_class).to be_nil
    end

    it 'ignores non-markdown files' do
      stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/logo.png' => 'binary', 'docs/notes.txt' => 'x' })

      described_class.perform_now(set.id)

      expect(set.documentation_pages.pluck(:path)).to contain_exactly('a.md')
    end

    # Positive iteration over the extension whitelist: shrinking
    # MARKDOWN_EXTENSIONS to just '.md' must break this test.
    it 'syncs .markdown files too, matching the extension case-insensitively' do
      stub_cloner_with(files: { 'docs/long.markdown' => '# Long', 'docs/UPPER.MD' => '# Upper' })

      described_class.perform_now(set.id)

      expect(set.documentation_pages.pluck(:path)).to contain_exactly('long.markdown', 'UPPER.MD')
    end
  end

  describe 'run metadata (trigger + user)' do
    it "records the default 'manual' trigger and no user for a bare run" do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })

      described_class.perform_now(set.id)

      run = set.documentation_sync_runs.recent.first
      expect(run.trigger).to eq('manual')
      expect(run.triggered_by_user_id).to be_nil
    end

    it 'records a passed-through trigger and triggering user (Actor/Slice-2 seam)' do
      user = create(:user)
      stub_cloner_with(files: { 'docs/a.md' => '# A' })

      described_class.perform_now(set.id, trigger: 'polling', triggered_by_user_id: user.id)

      run = set.documentation_sync_runs.recent.first
      expect(run.trigger).to eq('polling')
      expect(run.triggered_by_user_id).to eq(user.id)
    end

    it 'records the trigger on a failed run too' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new('git clone failed: Repository not found'))

      described_class.perform_now(set.id, trigger: 'polling')

      run = set.documentation_sync_runs.recent.first
      expect(run.status).to eq('failed')
      expect(run.trigger).to eq('polling')
    end

    it 'truncates an oversized error message to the limit (git stderr can be huge)' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new("Repository not found #{'x' * 5000}"))

      described_class.perform_now(set.id)

      message = set.documentation_sync_runs.recent.first.error_message
      expect(message.length).to eq(described_class::ERROR_MESSAGE_LIMIT)
    end
  end

  describe 'soft-removal of vanished files' do
    it 'marks a page removed when its source file disappears' do
      stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/b.md' => '# B' })
      described_class.perform_now(set.id)
      expect(set.documentation_pages.present_pages.count).to eq(2)

      stub_cloner_with(files: { 'docs/a.md' => '# A' }, commit: 'commit-sha-2')
      described_class.perform_now(set.id)

      expect(set.documentation_pages.present_pages.pluck(:path)).to contain_exactly('a.md')
      expect(set.documentation_pages.find_by(path: 'b.md')).to be_removed
      expect(set.documentation_sync_runs.recent.first.pages_removed).to eq(1)
    end

    it 'revives a removed page when the file returns' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)
      set.documentation_pages.find_by(path: 'a.md').update!(removed_at: Time.current)

      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)

      expect(set.documentation_pages.find_by(path: 'a.md')).not_to be_removed
    end

    # Cross-scope isolation: removal must be scoped to THE synced set — an
    # unscoped `DocumentationPage.where.not(path: seen)` would soft-remove
    # every other set's pages on each sync.
    it 'does not touch pages of other sets' do
      other_set = create(:documentation_set, project: project, name: 'Anderes Set')
      other_page = create(:documentation_page, documentation_set: other_set, path: 'only-elsewhere.md')

      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)

      expect(other_page.reload).not_to be_removed
    end
  end

  describe 'link and image rewriting' do
    it 'rewrites internal .md links and relative image sources' do
      stub_cloner_with(files: {
                         'docs/intro.md' => 'See [setup](guide/setup.md) and ![logo](img/logo.png)',
                         'docs/guide/setup.md' => '# Setup'
                       })

      described_class.perform_now(set.id)

      html = set.documentation_pages.find_by(path: 'intro.md').rendered_html
      expect(html).to include('/documentation')
      expect(html).to include('page=guide%2Fsetup.md').or include('page=guide/setup.md')
      expect(html).to include('raw.githubusercontent.com')
    end
  end

  describe 'incremental change detection' do
    it 'does not re-render a page whose content is unchanged' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)

      # Second identical sync must skip rendering (the whole point of git_blob_sha).
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      expect(Documentation::MarkdownRenderer).not_to receive(:new)
      described_class.perform_now(set.id)
    end

    it 're-renders and updates a page whose content changed' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)
      original_sha = set.documentation_pages.find_by(path: 'a.md').git_blob_sha

      stub_cloner_with(files: { 'docs/a.md' => '# A, now longer' })
      described_class.perform_now(set.id)

      page = set.documentation_pages.find_by(path: 'a.md')
      expect(page.markdown_body).to eq('# A, now longer')
      expect(page.git_blob_sha).not_to eq(original_sha)
    end

    it 'computes the canonical git blob SHA (empty file → git empty-blob SHA)' do
      stub_cloner_with(files: { 'docs/empty.md' => '' })
      described_class.perform_now(set.id)

      # Pins the exact "blob <len>\\0<content>" hash format used by `git hash-object`.
      expect(set.documentation_pages.find_by(path: 'empty.md').git_blob_sha)
        .to eq('e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')
    end

    it 'hashes multibyte content by BYTE size, not character length' do
      # 20 characters but 26 bytes — a `content.length` mutant in the blob header
      # would produce a different SHA. Expected value is authoritative:
      #   printf '# Über uns\n\nGrüße 🚀\n' | git hash-object --stdin
      stub_cloner_with(files: { 'docs/umlaut.md' => "# Über uns\n\nGrüße 🚀\n" })
      described_class.perform_now(set.id)

      expect(set.documentation_pages.find_by(path: 'umlaut.md').git_blob_sha)
        .to eq('01fe19201a94e9dded9112a2a3e0db5f6f15cc57')
    end
  end

  describe 'title extraction' do
    def title_for(content, path: 'docs/page.md')
      stub_cloner_with(files: { path => content })
      described_class.perform_now(set.id)
      set.documentation_pages.find_by(path: path.delete_prefix('docs/')).title
    end

    it 'uses the first H1' do
      expect(title_for("# Real Title\n\nbody")).to eq('Real Title')
    end

    it 'uses the first H1 even when it is not the first line' do
      expect(title_for("intro paragraph\n\n# Real Title\n")).to eq('Real Title')
    end

    it 'does not treat an H2 as the title, falling back to the filename' do
      expect(title_for("## Subheading\n\nbody", path: 'docs/sub.md')).to eq('Sub')
    end

    it 'humanizes the filename when there is no heading' do
      expect(title_for('just body', path: 'docs/getting-started.md')).to eq('Getting Started')
    end
  end

  describe 'logbook (Slice 2)' do
    def git_commit(sha:, message:, committed_at: Time.current, author: 'Ada')
      Documentation::GitLogReader::Commit.new(sha: sha, author_name: author,
                                              committed_at: committed_at, message: message)
    end

    def stub_git_log(commits)
      reader = instance_double(Documentation::GitLogReader, commits: commits)
      allow(Documentation::GitLogReader).to receive(:new).and_return(reader)
    end

    it 'stores the commits touching the docs folder on a successful sync' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      stub_git_log([git_commit(sha: 'a' * 40, message: 'docs: intro')])

      described_class.perform_now(set.id)

      commit = set.documentation_commits.sole
      expect(commit.message).to eq('docs: intro')
      expect(commit.author_name).to eq('Ada')
    end

    it 'does not duplicate already-known commits on the next sync (append-only dedup)' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      stub_git_log([git_commit(sha: 'a' * 40, message: 'docs: intro')])
      described_class.perform_now(set.id)

      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      stub_git_log([git_commit(sha: 'a' * 40, message: 'docs: intro'),
                    git_commit(sha: 'b' * 40, message: 'docs: more')])

      expect { described_class.perform_now(set.id) }.to change(DocumentationCommit, :count).by(1)
    end

    it 'truncates oversized commit fields instead of crashing the sync' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      stub_git_log([git_commit(sha: 'a' * 40, message: 'm' * 5000)])

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('ready')
      expect(set.documentation_commits.sole.message.length).to eq(described_class::COMMIT_FIELD_LIMIT)
    end

    # Best-effort contract: the logbook is auxiliary — a git-log failure (here:
    # the stubbed clone dir is a plain directory, not a git repo) must NOT turn
    # a successful page sync into a failed run.
    it 'keeps the sync ready when reading the git log fails' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      # No stub_git_log: the real reader runs against the non-git tmpdir and raises.

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('ready')
      expect(set.documentation_commits.count).to eq(0)
    end
  end

  describe 'failure taxonomy (DT4)' do
    it 'records path_not_found when the docs folder is missing' do
      stub_cloner_with(files: { 'README.md' => '# Top-level, not under docs/' })

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.error_class).to eq('path_not_found')
    end

    it 'classifies an authentication clone failure as auth' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new('git clone failed (exit 128): Authentication failed'))

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.error_class).to eq('auth')
    end

    it 'classifies a missing repository as source_deleted' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new('git clone failed: Repository not found'))

      described_class.perform_now(set.id)

      expect(set.documentation_sync_runs.recent.first.error_class).to eq('source_deleted')
    end

    it 'falls back to repo_unreachable for an unrecognised clone failure' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::TimeoutError.new('git clone timed out after 90s'))

      described_class.perform_now(set.id)

      expect(set.documentation_sync_runs.recent.first.error_class).to eq('repo_unreachable')
    end

    it 'keeps last_synced_at/commit pointing at the last SUCCESS when a later sync fails' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)
      set.reload
      success_at = set.last_synced_at
      success_commit = set.last_synced_commit
      expect(success_at).to be_present # guard: the success actually stamped

      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new('git clone failed: Repository not found'))
      described_class.perform_now(set.id)

      set.reload
      expect(set.sync_status).to eq('failed')
      expect(set.last_synced_at).to eq(success_at)
      expect(set.last_synced_commit).to eq(success_commit)
    end

    it 'records markdown_invalid when a page fails to render' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      broken = instance_double(Documentation::MarkdownRenderer)
      allow(broken).to receive(:render_with_references).and_raise(StandardError.new('render blew up'))
      allow(Documentation::MarkdownRenderer).to receive(:new).and_return(broken)

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.error_class).to eq('markdown_invalid')
    end
  end

  # The ls-remote cost guard: polling must not pay a full clone when nothing
  # changed — but ONLY polling, and only from a clean ready state.
  describe 'polling skip (unchanged remote tip)' do
    before do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id) # previous successful sync at commit-sha-1
    end

    it 'skips the clone and records nothing when the tip is unchanged' do
      cloner = stub_cloner_with(files: { 'docs/a.md' => '# A' }, remote_head: 'commit-sha-1')

      expect do
        described_class.perform_now(set.id, trigger: 'polling')
      end.not_to change(DocumentationSyncRun, :count)

      expect(cloner).not_to have_received(:call)
      expect(set.reload.sync_status).to eq('ready')
    end

    it 'runs the full sync when the remote tip moved' do
      stub_cloner_with(files: { 'docs/a.md' => '# A v2' }, commit: 'commit-sha-2', remote_head: 'commit-sha-2')

      described_class.perform_now(set.id, trigger: 'polling')

      expect(set.reload.last_synced_commit).to eq('commit-sha-2')
    end

    it 'still runs a MANUAL sync on an unchanged tip (repair-tool contract)' do
      cloner = stub_cloner_with(files: { 'docs/a.md' => '# A' }, remote_head: 'commit-sha-1')

      expect do
        described_class.perform_now(set.id)
      end.to change(DocumentationSyncRun, :count).by(1)

      expect(cloner).to have_received(:call)
    end

    it 'retries a failed set even when the tip is unchanged (failure may be transient)' do
      set.update_columns(sync_status: 'failed')
      cloner = stub_cloner_with(files: { 'docs/a.md' => '# A' }, remote_head: 'commit-sha-1')

      described_class.perform_now(set.id, trigger: 'polling')

      expect(cloner).to have_received(:call)
      expect(set.reload.sync_status).to eq('ready')
    end

    it 'fails open into a full sync when ls-remote yields nothing' do
      cloner = stub_cloner_with(files: { 'docs/a.md' => '# A' }, remote_head: nil)

      described_class.perform_now(set.id, trigger: 'polling')

      expect(cloner).to have_received(:call)
    end
  end

  # Defense in depth, second layer: the model validates path_prefix, but a row
  # written past validations (update_columns, old data) must STILL not make the
  # job read files outside the cloned repository — Pathname#join swaps the base
  # for absolute paths and keeps ../ segments.
  describe 'path_prefix containment guard' do
    it 'fails with path_not_found instead of reading outside the clone (../)' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      set.update_columns(path_prefix: '../')

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.error_class).to eq('path_not_found')
      expect(set.documentation_pages.count).to eq(0)
    end

    it 'fails with path_not_found instead of reading an absolute path' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      set.update_columns(path_prefix: '/')

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.error_class).to eq('path_not_found')
      expect(set.documentation_pages.count).to eq(0)
    end

    it 'still allows docs at the repository root (path_prefix ".")' do
      stub_cloner_with(files: { 'root.md' => '# Root' })
      set.update_columns(path_prefix: '.')

      described_class.perform_now(set.id)

      expect(set.reload.sync_status).to eq('ready')
      expect(set.documentation_pages.pluck(:path)).to include('root.md')
    end
  end

  describe 'advisory lock release on crash (T5)' do
    let(:lock_id) { Zlib.crc32("documentation_sync:#{set.id}") }

    it 'releases the per-set advisory lock even when the job crashes mid-run' do
      stub_cloner_raising(RuntimeError.new('boom mid-clone'))

      expect { described_class.perform_now(set.id) }.to raise_error(RuntimeError, /boom/)

      # No advisory lock left in pg_locks for this key → the job's ensure
      # released it. A leaked lock would leave one row here and deadlock resyncs.
      held = ActiveRecord::Base.connection.select_value(
        'SELECT count(*) FROM pg_locks ' \
        "WHERE locktype = 'advisory' AND classid = 0 AND objid = #{lock_id} AND objsubid = 1"
      )
      expect(held).to eq(0)
    end

    it 'still records a failed run before crashing' do
      stub_cloner_raising(RuntimeError.new('boom'))

      expect { described_class.perform_now(set.id) }.to raise_error(RuntimeError)

      expect(set.reload.sync_status).to eq('failed')
      expect(set.documentation_sync_runs.recent.first.status).to eq('failed')
    end
  end

  describe 'unknown set' do
    it 'is a no-op for a missing id' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to change(DocumentationSyncRun, :count)
    end
  end

  # Chat-grounding ingestion (Slice 3, part 3a): a successful sync fans out one
  # EmbeddingProcessingJob per CHANGED page, and soft-removal purges a page's
  # fragments so gone docs stop grounding the chat.
  #
  # NOTE spec/support/jobs_helper.rb globally stubs EmbeddingProcessingJob.perform_later
  # to a no-op spy, so these assert on that spy (have_received / receive) rather than
  # on the enqueue queue — the seam test below resets the stub to run the real chain.
  describe 'embedding fan-out (ingestion)' do
    it 'enqueues an embedding job for each page created on the first sync' do
      stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/b.md' => '# B' })

      described_class.perform_now(set.id)

      a = set.documentation_pages.find_by(path: 'a.md')
      b = set.documentation_pages.find_by(path: 'b.md')
      expect(EmbeddingProcessingJob).to have_received(:perform_later)
        .with(record_class: DocumentationPage, record_id: a.id, fragment_association: :fragments)
      expect(EmbeddingProcessingJob).to have_received(:perform_later)
        .with(record_class: DocumentationPage, record_id: b.id, fragment_association: :fragments)
    end

    it 'enqueues nothing when a resync finds no changed pages (git_blob_sha skip)' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)

      stub_cloner_with(files: { 'docs/a.md' => '# A' }) # identical content
      # A fresh expectation, set AFTER the first sync, only guards the second one.
      expect(EmbeddingProcessingJob).not_to receive(:perform_later)
      described_class.perform_now(set.id)
    end

    it 'enqueues only the changed page on a partial re-sync' do
      stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/b.md' => '# B' })
      described_class.perform_now(set.id)
      changed = set.documentation_pages.find_by(path: 'a.md')
      unchanged = set.documentation_pages.find_by(path: 'b.md')

      stub_cloner_with(files: { 'docs/a.md' => '# A changed', 'docs/b.md' => '# B' }, commit: 'commit-sha-2')
      expect(EmbeddingProcessingJob).to receive(:perform_later)
        .with(record_class: DocumentationPage, record_id: changed.id, fragment_association: :fragments)
      expect(EmbeddingProcessingJob).not_to receive(:perform_later)
        .with(record_class: DocumentationPage, record_id: unchanged.id, fragment_association: :fragments)

      described_class.perform_now(set.id)
    end

    it 'enqueues no embedding job when the sync fails' do
      stub_cloner_raising(Lalabase::Indexer::GitCloner::CloneFailedError.new('git clone failed: Repository not found'))

      described_class.perform_now(set.id)

      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # Best-effort fan-out: the sync is already recorded ready before we enqueue, so a
    # queue hiccup must NOT flip it to failed or record a spurious second run — the
    # pages are saved (flag nil) and get healed by a re-index / next change.
    it 'keeps the sync ready (single run) when the embedding fan-out raises' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      allow(EmbeddingProcessingJob).to receive(:perform_later).and_raise(StandardError.new('queue down'))

      expect { described_class.perform_now(set.id) }.not_to raise_error

      expect(set.reload.sync_status).to eq('ready')
      expect(set.documentation_sync_runs.count).to eq(1)
      expect(set.documentation_sync_runs.recent.first.status).to eq('ready')
    end

    # Chain completeness: soft-removal purged the fragments, so when the file
    # returns the page MUST re-embed even if its content is byte-identical (the
    # revive path is a "change" precisely because removed_at flips back to nil).
    it 're-enqueues the embedding when a removed page is revived (fragments were purged)' do
      stub_cloner_with(files: { 'docs/a.md' => '# A' })
      described_class.perform_now(set.id)
      page = set.documentation_pages.find_by(path: 'a.md')
      page.update!(removed_at: Time.current)

      stub_cloner_with(files: { 'docs/a.md' => '# A' }) # same content, file back
      expect(EmbeddingProcessingJob).to receive(:perform_later)
        .with(record_class: DocumentationPage, record_id: page.id, fragment_association: :fragments)

      described_class.perform_now(set.id)
    end

    # Stubs the PROVIDER, not EmbeddingProcessingService#generate_embedding. The earlier
    # version stubbed the latter and returned a bare vector, while the real method returns
    # [embedding, total_tokens] — so `embedding, tokens = ...` destructured the vector into
    # its first float, every fragment write failed, and the examples reported "no fragment"
    # instead of "your stub has the wrong shape". Stubbing one level down keeps
    # generate_embedding real, so the tuple contract stays under test.
    def stub_embed_provider!
      # 1536 dims on purpose: that is Indexer::EmbeddingColumns::INLINE_DIMS, so the fragment
      # takes the inline-vector path. A different width would route into the sidecar and these
      # examples would assert against the wrong storage.
      provider = instance_double(
        Lalabase::Llm::Provider,
        embed_with_usage: { embedding: Array.new(1536, 0.1), total_tokens: 5 },
        expected_embedding_dims: 1536,
        default_embedding_model: 'text-embedding-3-small',
        provider_name: 'openai',
        billing_credential: nil
      )
      allow_any_instance_of(EmbeddingProcessingService).to receive(:embed_provider).and_return(provider)
    end

    # Seam test: run the WHOLE chain through the real ActiveJob (de)serialization —
    # sync enqueues, the embedding job deserializes DocumentationPage + id and runs
    # the SHARED EmbeddingProcessingService, which must produce a fragment. Catches a
    # wrong record_class/association that a stubbed enqueue assertion would miss.
    it 'produces a fragment for the page end-to-end when the enqueued job runs' do
      # Undo the global perform_later stub so the job actually enqueues + runs, and
      # switch to the :test adapter so perform_enqueued_jobs drives it.
      RSpec::Mocks.space.proxy_for(EmbeddingProcessingJob).reset
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      stub_embed_provider!
      stub_cloner_with(files: { 'docs/a.md' => "# Deploy\n\nRun cap production deploy." })

      perform_enqueued_jobs { described_class.perform_now(set.id) }
      page = set.documentation_pages.find_by(path: 'a.md')

      expect(page.fragments.count).to be >= 1
      expect(page.fragments.first.plain_text_content).to include('Deploy')
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    # Connects the two halves of the pipeline that are otherwise tested apart: the
    # fragment the REAL service writes (real fragmentable_type/id/org) must be found
    # by the retrieval boundary scope for the set's project. Breaks if ingestion and
    # for_project_context ever disagree on the type string or the JOIN key.
    it 'produces a fragment the retrieval boundary (for_project_context) actually finds' do
      RSpec::Mocks.space.proxy_for(EmbeddingProcessingJob).reset
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      stub_embed_provider!
      stub_cloner_with(files: { 'docs/deploy.md' => "# Deploy\n\nRunbook steps." })

      perform_enqueued_jobs { described_class.perform_now(set.id) }
      page = set.documentation_pages.find_by(path: 'deploy.md')

      found = ActsAsTenant.with_tenant(organisation) do
        Fragment.for_project_context(project).where(fragmentable: page).to_a
      end
      expect(found).to be_present
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    describe 'soft-removal purges the page fragments' do
      it 'deletes the fragments of a page whose source file vanished' do
        stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/gone.md' => '# Gone' })
        described_class.perform_now(set.id)
        gone = set.documentation_pages.find_by(path: 'gone.md')
        fragment = create(:fragment, fragmentable: gone, organisation: organisation)

        stub_cloner_with(files: { 'docs/a.md' => '# A' }, commit: 'commit-sha-2')
        described_class.perform_now(set.id)

        expect(gone.reload).to be_removed
        expect(Fragment.where(id: fragment.id)).to be_empty
      end

      it 'keeps the fragments of a surviving page' do
        stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/gone.md' => '# Gone' })
        described_class.perform_now(set.id)
        survivor = set.documentation_pages.find_by(path: 'a.md')
        keep = create(:fragment, fragmentable: survivor, organisation: organisation)

        stub_cloner_with(files: { 'docs/a.md' => '# A' }, commit: 'commit-sha-2')
        described_class.perform_now(set.id)

        expect(Fragment.where(id: keep.id)).to be_present
      end

      # n>1 boundary: several pages vanish in one sync — ALL their fragments purged and
      # pages_removed counts them all (a mutant that removes only the first, or miscounts,
      # is caught here where the single-page test cannot see it).
      it 'purges fragments and counts pages_removed for MULTIPLE vanished pages' do
        stub_cloner_with(files: { 'docs/a.md' => '# A', 'docs/g1.md' => '# G1', 'docs/g2.md' => '# G2' })
        described_class.perform_now(set.id)
        g1 = set.documentation_pages.find_by(path: 'g1.md')
        g2 = set.documentation_pages.find_by(path: 'g2.md')
        f1 = create(:fragment, fragmentable: g1, organisation: organisation)
        f2 = create(:fragment, fragmentable: g2, organisation: organisation)

        stub_cloner_with(files: { 'docs/a.md' => '# A' }, commit: 'commit-sha-2')
        described_class.perform_now(set.id)

        expect(g1.reload).to be_removed
        expect(g2.reload).to be_removed
        expect(Fragment.where(id: [f1.id, f2.id])).to be_empty
        expect(set.documentation_sync_runs.recent.first.pages_removed).to eq(2)
      end
    end
  end

  # Slice 4: a lalabase:// link in a synced page becomes an in-app link AND a Reference
  # row. These cover the whole chain (file → sync → reference) and every mutation of it:
  # link added / removed / page unchanged / file vanished / target deleted.
  describe 'knowledge-link references (Slice 4)' do
    let(:note) { create(:note, project: project, organisation: organisation, title: 'Runbook') }

    def sync(files, commit: 'commit-sha-1')
      stub_cloner_with(files: files, commit: commit)
      described_class.perform_now(set.id)
    end

    def page_named(path)
      set.documentation_pages.find_by(path: path)
    end

    def create_document(title:)
      doc = create(:document, project: project, organisation: organisation)
      version = create(:document_version, document: doc, organisation: organisation, title: title)
      doc.update!(current_version: version)
      doc
    end

    it 'creates a Reference (with a title snapshot) from a page to a linked note' do
      sync({ 'docs/a.md' => "See [rb](lalabase://note/#{note.id})." })

      ref = page_named('a.md').outgoing_references.sole
      expect(ref.target).to eq(note)
      expect(ref.target_title_snapshot).to eq('Runbook')
    end

    it 'rebuilds (not appends): a later sync that drops the link removes the Reference' do
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})" })
      page = page_named('a.md')
      expect(page.outgoing_references).to be_present

      sync({ 'docs/a.md' => '# A, no link now' }, commit: 'commit-sha-2')
      expect(page.reload.outgoing_references).to be_empty
    end

    it 'repoints a reference when the link target changes (old target out, new target in)' do
      other_note = create(:note, project: project, organisation: organisation, title: 'Other')
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})" })
      page = page_named('a.md')
      expect(page.outgoing_references.map(&:target)).to eq([note])

      # Same file path, edited to point at a DIFFERENT note: the old ref must go, the new
      # one appear — a pure "append" would leave both (this is the rebuild's whole point).
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{other_note.id})" }, commit: 'commit-sha-2')
      expect(page.reload.outgoing_references.map(&:target)).to eq([other_note])
    end

    it 'leaves references untouched for an UNCHANGED page (blob-SHA skip keeps the row id)' do
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})" })
      ref_id = page_named('a.md').outgoing_references.sole.id

      # Identical content again → the page is skipped entirely, so the SAME row survives.
      # A blind delete+reinsert on every sync would churn the id (and, later, backlinks).
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})" }, commit: 'commit-sha-2')
      expect(page_named('a.md').outgoing_references.pluck(:id)).to eq([ref_id])
    end

    it 'purges the references of a page whose source file vanished (soft-removal)' do
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})", 'docs/keep.md' => '# Keep' })
      page = page_named('a.md')
      expect(page.outgoing_references).to be_present

      sync({ 'docs/keep.md' => '# Keep' }, commit: 'commit-sha-2')
      expect(page.reload).to be_removed
      expect(Reference.where(source_type: 'DocumentationPage', source_id: page.id)).to be_empty
    end

    it 'keeps the Reference as a tombstone when the TARGET note is hard-deleted' do
      sync({ 'docs/a.md' => "[rb](lalabase://note/#{note.id})" })
      ref = page_named('a.md').outgoing_references.sole

      note.destroy!

      ref.reload
      expect(ref.target).to be_nil
      expect(ref.target_title_snapshot).to eq('Runbook')
    end

    it 'indexes references to BOTH a note and a document from the same page (mixed types)' do
      document = create_document(title: 'Design Doc')

      sync({ 'docs/a.md' => "[n](lalabase://note/#{note.id}) and [d](lalabase://document/#{document.id})" })

      refs = page_named('a.md').outgoing_references
      expect(refs.map(&:target)).to contain_exactly(note, document)
      expect(refs.find { |ref| ref.target == document }.target_title_snapshot).to eq('Design Doc')
    end

    it 'indexes a document with NO current_version — reference with a nil snapshot, no crash' do
      # A document without a current_version has a nil #title; the rebuild must still
      # create the reference (target present) with a nil target_title_snapshot.
      document = create(:document, project: project, organisation: organisation)

      sync({ 'docs/a.md' => "[d](lalabase://document/#{document.id})" })

      ref = page_named('a.md').outgoing_references.sole
      expect(ref.target).to eq(document)
      expect(ref.target_title_snapshot).to be_nil
    end

    it 'truncates an over-long target title to 255 so the rebuild can never fail the sync' do
      long_note = create(:note, project: project, organisation: organisation, title: 'x' * 300)

      sync({ 'docs/a.md' => "[l](lalabase://note/#{long_note.id})" })

      expect(page_named('a.md').outgoing_references.sole.target_title_snapshot.length).to eq(255)
    end

    it 'does NOT create a reference for a link to a note in ANOTHER project (isolation)' do
      other_project = create(:project, organisation: organisation)
      foreign = create(:note, project: other_project, organisation: organisation)

      sync({ 'docs/a.md' => "[x](lalabase://note/#{foreign.id})" })

      expect(page_named('a.md').outgoing_references).to be_empty
    end
  end
end
