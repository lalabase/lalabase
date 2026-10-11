# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RepoReindexJob, type: :job do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', default_branch: 'main')
    end
  end
  let(:index) { repository.project_index }
  # Valid hex object names. GitHub always sends hex SHAs, and RepoReindexJob now
  # guards after_sha against COMMIT_SHA_PATTERN — a non-hex placeholder would be
  # rejected and fall back to a full re-index instead of the incremental path.
  let(:base_sha) { 'a' * 40 }
  let(:head_sha) { 'b' * 40 }

  before do
    ActsAsTenant.current_tenant = organisation
    index.update!(status: 'ready', last_indexed_commit: base_sha)
  end
  after { ActsAsTenant.current_tenant = nil }

  let(:embedding) { Array.new(1536, 0.1) }
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small',
                                                   expected_embedding_dims: 1536)
  end
  let(:github_client) { instance_double(Lalabase::Github::Client) }

  def symbol_hash(qname, file)
    { symbol_type: 'class', name: qname, qualified_name: qname, file_path: file,
      start_line: 1, end_line: 3, signature: "class #{qname}; end", language: 'ruby', metadata: {} }
  end

  def stub_pipeline!(changed:, symbols_by_file: {})
    allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:changed_files).and_return(changed)

    cloner = instance_double(Lalabase::Indexer::GitCloner)
    allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
    allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake-clone'))

    walker = instance_double(Lalabase::Indexer::Symbols::Walker)
    allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
    allow(walker).to receive(:symbols_for) { |path| symbols_by_file.fetch(path, []) }

    allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
    allow(embed_provider).to receive(:embed_batch) { |texts:| texts.map { embedding } }
  end

  def existing_symbol(qname, file)
    create(:code_symbol, project_repository: repository, organisation: organisation,
                         qualified_name: qname, file_path: file)
  end

  def repo_symbol_qnames
    CodeSymbol.where(project_repository_id: repository.id).pluck(:qualified_name)
  end

  # GitHub webhooks bypass Pundit, so the per-org beta gate must be enforced in
  # the job itself — otherwise a disabled org keeps cloning + re-embedding on
  # every push. (Regression guard for the gate hole the strict review found.)
  describe 'per-org beta gate' do
    it 'no-ops when the org has the chat feature disabled — no clone, index untouched' do
      organisation.update!(code_indexing_enabled: false)
      expect(Lalabase::Github::Client).not_to receive(:new)
      expect(ProjectIndexerJob).not_to receive(:perform_later)

      described_class.perform_now(repository, after_sha: head_sha)

      expect(index.reload.last_indexed_commit).to eq(base_sha) # unchanged — nothing re-indexed
    end

    # GDPR AI opt-in (audit 2026-07-03): the same webhook path must also stop
    # for a chat-enabled org that has NOT opted in to AI — re-indexing embeds
    # repo content. A READY index stays ready (settling only applies to
    # in-progress states; see JobSupport#ai_enabled_or_settle_index!).
    it 'no-ops when the org has not opted in to AI — no clone, ready index untouched' do
      organisation.update!(code_indexing_enabled: true, ai_enabled: false)
      expect(Lalabase::Github::Client).not_to receive(:new)
      expect(ProjectIndexerJob).not_to receive(:perform_later)

      described_class.perform_now(repository, after_sha: head_sha)

      expect(index.reload.last_indexed_commit).to eq(base_sha)
      expect(index.status).to eq('ready') # settling only touches pending/indexing/stale
    end
  end

  describe 'incremental re-index' do
    it 'replaces symbols of a modified file, leaving other files untouched' do
      existing_symbol('Old::A', 'app/a.rb')
      keep = existing_symbol('Keep::B', 'app/b.rb')
      stub_pipeline!(
        changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
        symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] }
      )

      described_class.perform_now(repository, after_sha: head_sha)

      expect(repo_symbol_qnames).to contain_exactly('New::A', 'Keep::B')
      expect(CodeSymbol.exists?(keep.id)).to be true
    end

    # Write-both + Matrix row 11 (embedding v2 PR 2): the per-file swap must purge the
    # touched path's OLD CodeSymbol sidecar rows and write fresh ones for the new symbols.
    it 'purges the touched file\'s old sidecar rows and writes new ones; untouched files keep theirs' do
      old = existing_symbol('Old::A', 'app/a.rb')
      old_row = create(:content_embedding, organisation: organisation, embeddable: old)
      keep = existing_symbol('Keep::B', 'app/b.rb')
      keep_row = create(:content_embedding, organisation: organisation, embeddable: keep)
      stub_pipeline!(
        changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
        symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] }
      )

      described_class.perform_now(repository, after_sha: head_sha)

      expect(ContentEmbedding.exists?(old_row.id)).to be(false)  # cleared with its symbol
      expect(ContentEmbedding.exists?(keep_row.id)).to be(true)  # untouched file untouched
      new_symbol = CodeSymbol.find_by(qualified_name: 'New::A')
      expect(ContentEmbedding.find_by(embeddable: new_symbol)).to have_attributes(
        source_hash: ContentEmbedding.source_hash_for('class New::A; end'), indexed: true
      )
    end

    it 'deletes symbols of a removed file (inserts nothing for it)' do
      existing_symbol('Gone::A', 'app/gone.rb')
      stub_pipeline!(changed: [{ filename: 'app/gone.rb', previous_filename: nil, status: 'removed' }])

      described_class.perform_now(repository, after_sha: head_sha)

      expect(CodeSymbol.where(project_repository_id: repository.id, file_path: 'app/gone.rb')).to be_empty
    end

    it 'moves symbols on rename (old path cleared, new path indexed)' do
      existing_symbol('Renamed::X', 'app/old.rb')
      stub_pipeline!(
        changed: [{ filename: 'app/new.rb', previous_filename: 'app/old.rb', status: 'renamed' }],
        symbols_by_file: { 'app/new.rb' => [symbol_hash('Renamed::X', 'app/new.rb')] }
      )

      described_class.perform_now(repository, after_sha: head_sha)

      expect(CodeSymbol.where(project_repository_id: repository.id).pluck(:file_path)).to contain_exactly('app/new.rb')
    end

    it 'flips status to ready and records last_indexed_commit on success' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })

      described_class.perform_now(repository, after_sha: head_sha)

      expect(index.reload).to have_attributes(status: 'ready', last_indexed_commit: head_sha)
    end

    # M9-5 default: a push re-index SUCCESS stays silent (only the initial index
    # notifies). Catches a mutation that adds a notify call to this success path.
    it 'does NOT notify the connector on a successful push re-index' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      allow(Notifications::IndexOutcomeNotifier).to receive(:call)

      described_class.perform_now(repository, after_sha: head_sha)

      expect(Notifications::IndexOutcomeNotifier).not_to have_received(:call)
    end

    # The status UI shows "last indexed … ago" from last_indexed_at; a mutation
    # dropping it on the incremental success path would silently freeze that.
    it 'bumps last_indexed_at on incremental success' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      expect(index.last_indexed_at).to be_nil

      described_class.perform_now(repository, after_sha: head_sha)

      expect(index.reload.last_indexed_at).to be_within(5.seconds).of(Time.current)
    end

    # C1: index the EXACT pushed commit, not just default-branch HEAD (race under
    # rapid pushes). The job must hand the after_sha to GitCloner as ref:.
    it 'clones the exact pushed commit (passes ref: after_sha to GitCloner)' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })

      described_class.perform_now(repository, after_sha: head_sha)

      expect(Lalabase::Indexer::GitCloner).to have_received(:new).with(repository, ref: head_sha)
    end

    # C3 (documented edge): GitHub almost always sends previous_filename on a
    # rename; if it's missing, the OLD path's symbols are left in place (no wrong
    # data, just a stale extra entry) and the new path is indexed.
    it 'indexes the new path on a rename without previous_filename (old path left as-is)' do
      existing_symbol('Old::Orphan', 'app/old.rb')
      stub_pipeline!(changed: [{ filename: 'app/new.rb', previous_filename: nil, status: 'renamed' }],
                     symbols_by_file: { 'app/new.rb' => [symbol_hash('New::X', 'app/new.rb')] })

      described_class.perform_now(repository, after_sha: head_sha)

      expect(repo_symbol_qnames).to contain_exactly('New::X', 'Old::Orphan')
    end

    it 'handles a combined push (modified + removed + added) in a single pass' do
      existing_symbol('Mod::Old', 'app/mod.rb')
      existing_symbol('Del::X',   'app/del.rb')
      keep = existing_symbol('Keep::Y', 'app/keep.rb')
      stub_pipeline!(
        changed: [
          { filename: 'app/mod.rb', previous_filename: nil, status: 'modified' },
          { filename: 'app/del.rb', previous_filename: nil, status: 'removed' },
          { filename: 'app/new.rb', previous_filename: nil, status: 'added' }
        ],
        symbols_by_file: {
          'app/mod.rb' => [symbol_hash('Mod::New', 'app/mod.rb')],
          'app/new.rb' => [symbol_hash('New::Z', 'app/new.rb')]
        }
      )

      described_class.perform_now(repository, after_sha: head_sha)

      expect(repo_symbol_qnames).to contain_exactly('Mod::New', 'Keep::Y', 'New::Z')
      expect(CodeSymbol.exists?(keep.id)).to be true
    end

    # Only 'removed' is special-cased; every other status re-extracts. Catches a
    # mutation that over-broadens the reject (e.g. also skipping 'changed').
    it 'treats a "changed" status file like a modification' do
      existing_symbol('Ch::Old', 'app/c.rb')
      stub_pipeline!(changed: [{ filename: 'app/c.rb', previous_filename: nil, status: 'changed' }],
                     symbols_by_file: { 'app/c.rb' => [symbol_hash('Ch::New', 'app/c.rb')] })

      described_class.perform_now(repository, after_sha: head_sha)

      expect(repo_symbol_qnames).to contain_exactly('Ch::New')
    end

    # Cross-scope isolation: the delete is scoped to project_repository_id, not
    # just file_path. Dropping that scope would wipe another repo's same-path
    # symbols. (Defense in depth beyond tenant scoping — same org, other repo.)
    it 'never deletes another repository symbols sharing the same file_path' do
      other_repo = ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/other')
      end
      other_sym = create(:code_symbol, project_repository: other_repo, organisation: organisation,
                                       qualified_name: 'Other::A', file_path: 'app/a.rb')
      existing_symbol('Mine::A', 'app/a.rb')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('Mine::New', 'app/a.rb')] })

      described_class.perform_now(repository, after_sha: head_sha)

      expect(CodeSymbol.exists?(other_sym.id)).to be true
      expect(repo_symbol_qnames).to contain_exactly('Mine::New')
    end
  end

  describe 'Compare API contract' do
    # A base/head swap (or wrong full_name) yields the inverse/incorrect diff —
    # invisible if the stub ignores args. Pin them explicitly.
    it 'queries Compare with the repo full_name, base = last_indexed_commit, head = after_sha' do
      allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
      expect(github_client).to receive(:changed_files)
        .with(full_name: 'acme/backend', base: base_sha, head: head_sha).and_return([])

      described_class.perform_now(repository, after_sha: head_sha)
    end
  end

  describe 'full-reindex fallbacks' do
    it 'delegates to ProjectIndexerJob when there is no baseline commit' do
      index.update!(last_indexed_commit: nil)
      expect(Lalabase::Github::Client).not_to receive(:new)
      expect(ProjectIndexerJob).to receive(:perform_later).with(repository, trigger: 'push')
      described_class.perform_now(repository, after_sha: head_sha)
    end

    it 'delegates to ProjectIndexerJob AT the file cap (300 = GitHub likely truncated the list)' do
      capped = Array.new(described_class::MAX_INCREMENTAL_FILES) do |i|
        { filename: "f#{i}.rb", previous_filename: nil, status: 'modified' }
      end
      stub_pipeline!(changed: capped)
      expect(Lalabase::Indexer::GitCloner).not_to receive(:new)
      expect(ProjectIndexerJob).to receive(:perform_later).with(repository, trigger: 'push')
      described_class.perform_now(repository, after_sha: head_sha)
    end

    # Boundary counterpart: just UNDER the cap must stay incremental. Catches a
    # `>=` → `>` mutation that would skip the truncation guard. (At exactly the
    # cap we deliberately full-reindex — see the cap test above.)
    it 'stays incremental at MAX_INCREMENTAL_FILES - 1 (n-1 boundary)' do
      files = Array.new(described_class::MAX_INCREMENTAL_FILES - 1) do |i|
        { filename: "f#{i}.rb", previous_filename: nil, status: 'modified' }
      end
      stub_pipeline!(changed: files) # symbols_for → [] (unstubbed); incremental path still runs
      expect(ProjectIndexerJob).not_to receive(:perform_later)

      described_class.perform_now(repository, after_sha: head_sha)

      expect(index.reload).to have_attributes(status: 'ready', last_indexed_commit: head_sha)
    end

    it 'delegates to ProjectIndexerJob when the Compare API errors' do
      allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:changed_files).and_raise(Lalabase::Github::Client::NotFoundError)
      expect(ProjectIndexerJob).to receive(:perform_later).with(repository, trigger: 'push')
      described_class.perform_now(repository, after_sha: head_sha)
    end
  end

  describe 'after_sha validation (untrusted webhook input)' do
    # after_sha flows into git CLI args (GitCloner ref:) and the Compare URL. Anything
    # that is not a hex object name must fall back to a safe full re-index, never reach
    # git. These boundaries keep COMMIT_SHA_PATTERN from being silently weakened (drop a
    # bound, \z→\Z trailing-newline injection, allow uppercase/A-F, ...) — all
    # security-relevant since the value reaches git-CLI args.
    {
      'a git option' => '--upload-pack=evil',
      'too short (6 chars)' => 'abc123',
      'too long (65 chars)' => 'a' * 65,
      'uppercase hex' => 'ABC1234',
      'has an embedded newline' => "abc1234\nrm -rf /",
      'has a trailing newline' => "abc1234\n" # pins \z (not \Z, which matches before a trailing newline)
    }.each do |label, bad_sha|
      it "falls back to a full re-index when after_sha is #{label}" do
        # Assert BOTH not-received so this pins the GUARD specifically: an invalid SHA
        # must short-circuit BEFORE the Compare API (Github::Client) AND before git
        # (GitCloner). Without the Github::Client guard the test would also pass via
        # the Compare-error fallback, masking a weakened pattern.
        expect(Lalabase::Github::Client).not_to receive(:new)
        expect(Lalabase::Indexer::GitCloner).not_to receive(:new)
        expect(ProjectIndexerJob).to receive(:perform_later).with(repository, trigger: 'push')

        described_class.perform_now(repository, after_sha: bad_sha)
      end
    end

    # Boundaries that MUST be accepted (incremental path, no fallback): the 7-char
    # lower bound and the 64-char SHA-256 upper bound. Kill a `{7,64}` → `{8,64}` /
    # `{7,63}` / `+` mutation.
    it 'accepts an abbreviated 7-char hex SHA (lower boundary)' do
      stub_pipeline!(changed: [])
      expect(ProjectIndexerJob).not_to receive(:perform_later)

      described_class.perform_now(repository, after_sha: 'abc1234')

      expect(index.reload.last_indexed_commit).to eq('abc1234')
    end

    it 'accepts a full 64-char SHA-256 object name (upper boundary)' do
      stub_pipeline!(changed: [])
      expect(ProjectIndexerJob).not_to receive(:perform_later)

      described_class.perform_now(repository, after_sha: 'a' * 64)

      expect(index.reload.last_indexed_commit).to eq('a' * 64)
    end
  end

  describe 'index run history (incremental)' do
    it 'records an incremental run with the delta (files changed, symbols added/removed)' do
      changed = [
        { filename: 'app/a.rb',    previous_filename: nil, status: 'modified' },
        { filename: 'app/b.rb',    previous_filename: nil, status: 'modified' },
        { filename: 'app/gone.rb', previous_filename: nil, status: 'removed' }
      ]
      stub_pipeline!(changed: changed, symbols_by_file: {
                       'app/a.rb' => [symbol_hash('A', 'app/a.rb')],
                       'app/b.rb' => [symbol_hash('B', 'app/b.rb')]
                     })

      expect { described_class.perform_now(repository, after_sha: head_sha) }
        .to change(ProjectIndexRun, :count).by(1)

      run = ProjectIndexRun.order(:created_at).last
      expect(run).to have_attributes(
        status: 'ready', trigger: 'push', incremental: true, commit_sha: head_sha,
        files_count: 3, symbols_added: 2, symbols_removed: 1, triggered_by_user_id: nil
      )
    end
  end

  # A manual "reindex now" click carries no push payload, so after_sha is omitted
  # and the job resolves the branch head itself, then runs the SAME incremental
  # path as a push. The run is attributed to the clicking user and tagged 'manual'.
  describe 'manual trigger (no push payload)' do
    let(:triggerer) { create(:user) }

    def stub_head!(sha)
      allow(github_client).to receive(:latest_commit_sha)
        .with(full_name: 'acme/backend', branch: 'main').and_return(sha)
    end

    it 'resolves the branch head and re-indexes changed files incrementally' do
      existing_symbol('Old::A', 'app/a.rb')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] })
      stub_head!(head_sha)

      described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id)

      expect(repo_symbol_qnames).to contain_exactly('New::A')
      expect(index.reload).to have_attributes(status: 'ready', last_indexed_commit: head_sha)
    end

    it 'records the incremental run as trigger=manual, attributed to the clicking user' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      stub_head!(head_sha)

      expect { described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id) }
        .to change(ProjectIndexRun, :count).by(1)

      expect(ProjectIndexRun.order(:created_at).last)
        .to have_attributes(trigger: 'manual', status: 'ready', incremental: true,
                            commit_sha: head_sha, triggered_by_user_id: triggerer.id)
    end

    it 'clones the resolved head commit (passes ref: resolved_sha to GitCloner)' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      stub_head!(head_sha)

      described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id)

      expect(Lalabase::Indexer::GitCloner).to have_received(:new).with(repository, ref: head_sha)
    end

    # Base == head (repo already current) → nothing to do, but a manual click must
    # still leave a trace, unlike a no-op push. Records a 0-file ready run.
    it 'records a 0-file manual run when nothing changed (base == head)' do
      stub_pipeline!(changed: [])
      stub_head!(head_sha)
      expect(Lalabase::Indexer::GitCloner).not_to receive(:new) # nothing to clone

      expect { described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id) }
        .to change(ProjectIndexRun, :count).by(1)

      expect(ProjectIndexRun.order(:created_at).last)
        .to have_attributes(trigger: 'manual', status: 'ready', files_count: 0,
                            commit_sha: head_sha, triggered_by_user_id: triggerer.id)
      expect(index.reload.last_indexed_commit).to eq(head_sha)
    end

    # Counterpart contract: a NO-OP PUSH stays silent (no history row). Guards the
    # `trigger == 'manual'` condition on record_noop_run from being widened.
    it 'does NOT record a run for a no-op push (empty diff)' do
      stub_pipeline!(changed: [])

      expect { described_class.perform_now(repository, after_sha: head_sha) }
        .not_to change(ProjectIndexRun, :count)
    end

    # When HEAD can't be resolved (expired/invalid token — the reported bug), the
    # manual path must FAIL FAST with a clear, actionable message: NOT fall back to a
    # doomed full clone that only buries the real cause under a git exit code.
    describe 'head resolution fails (expired/invalid token)' do
      before do
        allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:latest_commit_sha).and_raise(Lalabase::Github::Client::AuthError)
      end

      it 'does NOT fall back to a full re-index and does NOT clone' do
        expect(ProjectIndexerJob).not_to receive(:perform_later)
        expect(Lalabase::Indexer::GitCloner).not_to receive(:new)

        expect { described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id) }
          .not_to raise_error
      end

      it 'marks the index failed with the actionable "update the token" message' do
        described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id)

        expect(index.reload.status).to eq('failed')
        expect(index.error_message).to eq(I18n.t('views.organisations.indexing.errors.auth_failed'))
      end

      it 'records a failed manual run attributed to the clicking user' do
        expect { described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id) }
          .to change(ProjectIndexRun, :count).by(1)

        expect(ProjectIndexRun.order(:created_at).last)
          .to have_attributes(trigger: 'manual', status: 'failed', triggered_by_user_id: triggerer.id)
      end

      it 'notifies the connector of the failure' do
        allow(Notifications::IndexOutcomeNotifier).to receive(:call)
        described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id)
        expect(Notifications::IndexOutcomeNotifier).to have_received(:call).with(hash_including(outcome: :failed))
      end
    end

    # A NotFoundError (repo gone / access lost) gets its own actionable message —
    # not the auth one — so the user isn't told to "update the token" for a deleted repo.
    it 'uses the repo-not-found message when HEAD resolution 404s' do
      allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:latest_commit_sha).and_raise(Lalabase::Github::Client::NotFoundError)

      described_class.perform_now(repository, trigger: 'manual', triggered_by_user_id: triggerer.id)

      expect(index.reload.error_message).to eq(I18n.t('views.organisations.indexing.errors.repo_not_found'))
    end
  end

  # Auth can also fail at the CLONE (a push, or a manual run where HEAD resolved but
  # the token died before the clone). GitCloner raises AuthenticationError; the index
  # badge must show the actionable message, not the raw git exit code.
  describe 'clone fails to authenticate' do
    it 'stores the actionable auth message on the index (not the raw git error)' do
      allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:changed_files)
        .and_return([{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }])
      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call)
        .and_raise(Lalabase::Indexer::GitCloner::AuthenticationError, 'git clone failed (exit 128): Authentication failed')

      expect { described_class.perform_now(repository, after_sha: head_sha) }
        .to raise_error(Lalabase::Indexer::GitCloner::AuthenticationError)

      expect(index.reload).to have_attributes(
        status: 'failed', error_message: I18n.t('views.organisations.indexing.errors.auth_failed')
      )
    end
  end

  describe 'index-run history is best-effort (never breaks a successful index)' do
    # JobSupport#record_index_run rescues StandardError so a history-write failure
    # cannot turn an otherwise-successful index into a failure ("must never break
    # the actual index"). Kills removal of that rescue.
    it 'still completes the index when writing the run history raises' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      allow(ProjectIndexRun).to receive(:create!).and_raise(StandardError, 'history write failed')

      expect { described_class.perform_now(repository, after_sha: head_sha) }.not_to raise_error
      expect(index.reload).to have_attributes(status: 'ready', last_indexed_commit: head_sha)
    end
  end

  describe 'empty diff' do
    it 'advances last_indexed_commit without cloning' do
      stub_pipeline!(changed: [])
      expect(Lalabase::Indexer::GitCloner).not_to receive(:new)
      described_class.perform_now(repository, after_sha: head_sha)
      expect(index.reload.last_indexed_commit).to eq(head_sha)
    end
  end

  describe 'failure handling' do
    it 'flips to failed and rolls back (no partial update) on embed failure' do
      existing_symbol('Old::A', 'app/a.rb')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] })
      allow(embed_provider).to receive(:embed_batch).and_raise(StandardError, 'boom')

      expect { described_class.perform_now(repository, after_sha: head_sha) }.to raise_error(StandardError)

      expect(index.reload.status).to eq('failed')
      expect(repo_symbol_qnames).to eq(['Old::A']) # delete rolled back with the failed insert
      expect(index.last_indexed_commit).to eq(base_sha) # not advanced
    end

    # Sidecar RecordNotUnique conflict (embedding v2 PR 2, Matrix row 11): the per-file
    # swap (purge old sidecars → delete_all old symbols → insert new symbols + sidecars)
    # runs in ONE CodeSymbol.transaction, so a conflicting sidecar insert rolls the WHOLE
    # swap back — the old symbol AND its sidecar row survive intact, leaving no orphaned or
    # half-written sidecar behind.
    it 'rolls the per-file swap back on a sidecar RecordNotUnique (old symbol + sidecar survive)' do
      old = existing_symbol('Old::A', 'app/a.rb')
      old_row = create(:content_embedding, organisation: organisation, embeddable: old)
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] })
      allow(ContentEmbedding).to receive(:insert_all).and_raise(
        ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint'
      )

      expect { described_class.perform_now(repository, after_sha: head_sha) }
        .to raise_error(ActiveRecord::RecordNotUnique)

      expect(index.reload.status).to eq('failed')
      expect(CodeSymbol.exists?(old.id)).to be(true)           # delete_all rolled back
      expect(ContentEmbedding.exists?(old_row.id)).to be(true) # purge rolled back with it
      expect(repo_symbol_qnames).to eq(['Old::A'])             # no New::A persisted
    end

    # M9-5: failures notify the connector (index_failed) regardless of trigger —
    # both jobs funnel failures through JobSupport#fail_index!.
    it 'notifies the connector when the re-index fails (index_failed)' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('New::A', 'app/a.rb')] })
      allow(embed_provider).to receive(:embed_batch).and_raise(StandardError, 'boom')
      allow(Notifications::IndexOutcomeNotifier).to receive(:call)

      expect { described_class.perform_now(repository, after_sha: head_sha) }.to raise_error(StandardError)
      expect(Notifications::IndexOutcomeNotifier).to have_received(:call).with(hash_including(outcome: :failed))
    end

    it 'redacts the access token from the failure error_message' do
      repository.update!(access_token: 'ghp_secrettoken')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      allow(embed_provider).to receive(:embed_batch).and_raise(StandardError, 'fail with ghp_secrettoken leaked')

      expect { described_class.perform_now(repository, after_sha: head_sha) }.to raise_error(StandardError)

      expect(index.reload.error_message).to include('[REDACTED]')
      expect(index.error_message).not_to include('ghp_secrettoken')
    end

    # error_message is only HALF the leak surface. The RE-RAISED exception is what
    # SolidQueue::FailedExecution + error trackers persist verbatim — a mutation
    # re-raising the original (un-scrubbed) error keeps error_message redacted but
    # leaks the token downstream. Assert the propagated exception is scrubbed too.
    it 'redacts the access token from the RE-RAISED exception, not just error_message' do
      repository.update!(access_token: 'ghp_secrettoken')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      allow(embed_provider).to receive(:embed_batch).and_raise(StandardError, 'fail with ghp_secrettoken leaked')

      expect { described_class.perform_now(repository, after_sha: head_sha) }
        .to(raise_error { |e| expect(e.message).not_to include('ghp_secrettoken') })
    end

    # The run history is a SECOND token-leak surface (its own redaction call-site in
    # JobSupport#record_index_run, independent of fail_index!). And the failed
    # INCREMENTAL run is otherwise untested — a deleted record_index_run in the
    # rescue would slip through. ProjectIndexerJob has the symmetric test.
    it 'records a FAILED incremental run with the token redacted from ITS error_message' do
      repository.update!(access_token: 'ghp_secrettoken')
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      allow(embed_provider).to receive(:embed_batch).and_raise(StandardError, 'boom ghp_secrettoken leaked')

      expect { described_class.perform_now(repository, after_sha: head_sha) }.to raise_error(StandardError)

      run = ProjectIndexRun.order(:created_at).last
      expect(run).to have_attributes(status: 'failed', trigger: 'push', incremental: true)
      expect(run.error_message).to include('[REDACTED]')
      expect(run.error_message).not_to include('ghp_secrettoken')
    end
  end

  describe 'repository deleted before perform' do
    # Both discard_on guards (DeserializationError / RecordNotFound) must keep a
    # push for an already-deleted repo from raising (it would otherwise retry
    # forever). perform_now honours discard_on via rescue_from.
    it 'discards instead of raising when the repository no longer exists' do
      destroyed = repository
      destroyed.destroy!
      expect { described_class.perform_now(destroyed, after_sha: head_sha) }.not_to raise_error
    end
  end

  describe 'tenant isolation' do
    it 'sets its own tenant from the repository organisation' do
      stub_pipeline!(changed: [{ filename: 'app/a.rb', previous_filename: nil, status: 'added' }],
                     symbols_by_file: { 'app/a.rb' => [symbol_hash('A', 'app/a.rb')] })
      ActsAsTenant.current_tenant = nil

      described_class.perform_now(repository, after_sha: head_sha)

      ActsAsTenant.with_tenant(organisation) do
        expect(repo_symbol_qnames).to eq(['A'])
      end
    end
  end
end
