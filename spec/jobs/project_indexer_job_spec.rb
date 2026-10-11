# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProjectIndexerJob, type: :job do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', default_branch: 'main')
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:chat_provider)  { instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai') }
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small',
                                                   expected_embedding_dims: 1536)
  end

  let(:fake_scan) do
    { readme: { name: 'README.md', content: '# X' }, manifests: {}, claude_md: nil,
      top_level: ['app/'], language_hint: 'ruby' }
  end

  let(:vision_result) do
    { content: 'A short vision.', language: 'en', model_used: 'gpt-4o-mini',
      token_usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 } }
  end

  let(:capabilities_result) do
    { capabilities: [
        { name: 'NS', description: 'desc1', key_modules: [] },
        { name: 'MT', description: 'desc2', key_modules: [] }
      ],
      language: 'en', model_used: 'gpt-4o-mini',
      token_usage: { input_tokens: 50, output_tokens: 100, total_tokens: 150 } }
  end

  let(:embedding) { Array.new(1536, 0.1) }

  # Stubs the non-walker half of the indexing pipeline shared by every example:
  # the LLM factory + embed provider, the GitCloner (yields a fake clone path),
  # the RepoScanner, and the Vision/Capability generators. Each describe block
  # layers its OWN Walker + embed_batch stub on top — the walker is the part that
  # actually varies between Layer-1 scenarios, so it stays out of here.
  def stub_index_pipeline!(scan: fake_scan, vision: vision_result, capabilities: capabilities_result)
    allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:repository_indexing, anything, lane: :chat).and_return(chat_provider)
    allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
    allow(embed_provider).to receive(:embed).and_return(embedding)
    allow(embed_provider).to receive(:default_embedding_model).and_return('text-embedding-3-small')

    cloner = instance_double(Lalabase::Indexer::GitCloner)
    allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
    allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake-clone'))
    allow(cloner).to receive(:cloned_commit).and_return('a' * 40)

    scanner = instance_double(Lalabase::Indexer::RepoScanner, call: scan)
    allow(Lalabase::Indexer::RepoScanner).to receive(:new).and_return(scanner)

    vision_gen = instance_double(Lalabase::Indexer::VisionGenerator, call: vision)
    allow(Lalabase::Indexer::VisionGenerator).to receive(:new).and_return(vision_gen)
    cap_gen = instance_double(Lalabase::Indexer::CapabilityGenerator, call: capabilities)
    allow(Lalabase::Indexer::CapabilityGenerator).to receive(:new).and_return(cap_gen)
  end

  def stub_external!(scan: fake_scan, vision: vision_result, capabilities: capabilities_result,
                     layer_1_symbols: [])
    stub_index_pipeline!(scan: scan, vision: vision, capabilities: capabilities)
    allow(embed_provider).to receive(:embed_batch).and_return([])

    # M6: Layer 1 walker — stub to yield the supplied symbols across a few files.
    walker = instance_double(Lalabase::Indexer::Symbols::Walker)
    allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
    allow(walker).to receive(:file_count).and_return(layer_1_symbols.empty? ? 0 : 1)
    allow(walker).to receive(:each_file_symbols) do |&blk|
      if blk
        blk.call(layer_1_symbols, 'app/foo.rb') unless layer_1_symbols.empty?
        nil
      else
        Enumerator.new { |y| y << [layer_1_symbols, 'app/foo.rb'] unless layer_1_symbols.empty? }
      end
    end
    return unless layer_1_symbols.any?

    allow(embed_provider).to receive(:embed_batch).and_return(layer_1_symbols.map { embedding })
  end

  describe 'queue configuration' do
    it 'is queued to :indexing' do
      expect(described_class.queue_name).to eq('indexing')
    end
  end

  describe 'per-org beta gate (M10/D3)' do
    # The initial-index path is gated in the job itself (JobSupport#code_indexing_enabled?
    # plus #ai_enabled_or_settle_index!),
    # not just in Pundit. Symmetric with RepoReindexJob's gate test — the strict review
    # found the re-index path tested but the initial path NOT, so deleting the gate line
    # here would have slipped through. A disabled org must NOT clone or embed on connect.
    it 'no-ops when the org has the chat feature disabled — no clone, no embedding' do
      organisation.update!(code_indexing_enabled: false)
      expect(Lalabase::Indexer::GitCloner).not_to receive(:new)
      expect(Lalabase::Llm::Factory).not_to receive(:for_embeddings)

      described_class.new.perform(repository)

      expect(repository.reload.project_index.status).to eq('pending') # untouched
    end

    # GDPR AI opt-in (audit 2026-07-03): same entry point, DIFFERENT skip
    # semantics than the beta gate above. The beta gate leaves the index
    # untouched (operator flag, index waits); the AI gate SETTLES it as failed
    # with a marker — 'pending' counts as in-progress, so leaving it would
    # permanently refuse the manual reindex button (red-team deadlock finding),
    # and activation re-enqueues exactly the marker-settled indexes.
    it 'skips without cloning and settles the pending index as failed with the AI marker' do
      organisation.update!(code_indexing_enabled: true, ai_enabled: false)
      expect(Lalabase::Indexer::GitCloner).not_to receive(:new)
      expect(Lalabase::Llm::Factory).not_to receive(:for_embeddings)

      described_class.new.perform(repository)

      index = repository.reload.project_index
      expect(index.status).to eq('failed')
      expect(index.error_message).to eq(Lalabase::Indexer::JobSupport::AI_DISABLED_ERROR_MESSAGE)
    end
  end

  describe 'happy path (first repo for project)' do
    before { stub_external! }

    it 'transitions ProjectIndex through indexing → ready' do
      described_class.new.perform(repository)
      idx = repository.reload.project_index
      expect(idx.status).to eq('ready')
      expect(idx.layer_4_status).to eq('ready')
      expect(idx.layer_3_status).to eq('ready')
      expect(idx.layer_1_status).to eq('ready')
      expect(idx.last_indexed_at).to be_within(5.seconds).of(Time.current)
    end

    # M9-5: the initial index notifies the connector on success. Spy on the
    # notifier (its own spec covers what it does) — this pins the job→notifier
    # wiring, so removing the call turns this red.
    it 'notifies the connector that the initial index completed' do
      allow(Notifications::IndexOutcomeNotifier).to receive(:call)
      described_class.new.perform(repository)
      expect(Notifications::IndexOutcomeNotifier).to have_received(:call).with(hash_including(outcome: :completed))
    end

    it 'creates exactly one ProjectLayer4Vision for the project' do
      expect { described_class.new.perform(repository) }.to change(ProjectLayer4Vision, :count).by(1)
      vision = ProjectLayer4Vision.find_by(project_id: project.id)
      expect(vision.content).to eq('A short vision.')
      expect(vision.auto_generated).to be(true)
      expect(vision.language).to eq('en')
    end

    it 'persists embeddings on the vision and capabilities (provider name recorded)' do
      described_class.new.perform(repository)
      vision = ProjectLayer4Vision.find_by(project_id: project.id)
      capabilities = ProjectCapability.where(project_id: project.id)

      # Provenance lives on the sidecar row since PR 7 — and as the full TRIPLE.
      expect(ContentEmbedding.find_by(embeddable: vision).embedding_provider).to eq('openai')
      expect(ContentEmbedding.where(embeddable_type: 'ProjectCapability', embeddable_id: capabilities.ids)
                             .pluck(:embedding_provider).uniq).to eq(['openai'])
    end

    # Catches a real bug: embedding_model must record the EMBEDDING model
    # (e.g. text-embedding-3-small), NOT the chat model that produced the text.
    # Mixing them up breaks vector-space tracking for future re-index migrations.
    it 'records the embedding model — not the chat model — on Vision and Capabilities' do
      allow(embed_provider).to receive(:default_embedding_model).and_return('text-embedding-3-small')
      described_class.new.perform(repository)
      vision = ProjectLayer4Vision.find_by(project_id: project.id)
      capabilities = ProjectCapability.where(project_id: project.id)

      vision_row = ContentEmbedding.find_by(embeddable: vision)
      expect(vision_row.embedding_model).to eq('text-embedding-3-small')
      expect(vision_row.embedding_model).not_to eq('gpt-4o-mini')
      expect(ContentEmbedding.where(embeddable_type: 'ProjectCapability', embeddable_id: capabilities.ids)
                             .pluck(:embedding_model).uniq).to eq(['text-embedding-3-small'])
    end

    it 'creates one ProjectCapability per generator entry' do
      expect { described_class.new.perform(repository) }
        .to change(ProjectCapability.where(project_id: project.id), :count).by(2)
      names = ProjectCapability.where(project_id: project.id).pluck(:name)
      expect(names).to contain_exactly('NS', 'MT')
    end

    it 'clears any prior error_message on the index' do
      # repo callback already created a ProjectIndex; flip it to a failed state
      idx = repository.project_index
      idx.update!(status: 'failed', error_message: 'previous boom')
      described_class.new.perform(repository)
      expect(idx.reload.error_message).to be_nil
    end
  end

  describe 'multi-repo policy: skip Layer 4/3 when Vision already exists' do
    before do
      stub_external!
      create(:project_layer4_vision, project: project, organisation: organisation,
                                     content: 'pre-existing', auto_generated: true)
    end

    it 'does NOT create a second ProjectLayer4Vision (1:1 with project)' do
      expect { described_class.new.perform(repository) }.not_to change(ProjectLayer4Vision, :count)
    end

    it 'does NOT regenerate capabilities (preserves existing project metadata)' do
      expect { described_class.new.perform(repository) }
        .not_to change(ProjectCapability.where(project_id: project.id), :count)
    end

    it 'still flips status to ready (the repo itself is indexed; layer 1 stays pending)' do
      described_class.new.perform(repository)
      expect(repository.reload.project_index.status).to eq('ready')
    end

    it 'does NOT call the VisionGenerator at all (cost-saving)' do
      expect(Lalabase::Indexer::VisionGenerator).not_to receive(:new)
      described_class.new.perform(repository)
    end
  end

  describe 'failure paths' do
    it 'flips status to failed when GitCloner raises and re-raises for SolidQueue retry' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:repository_indexing, anything, lane: :chat).and_return(chat_provider)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_raise(Lalabase::Indexer::GitCloner::CloneFailedError, 'fatal: nope')

      expect do
        described_class.new.perform(repository)
      end.to raise_error(Lalabase::Indexer::GitCloner::CloneFailedError)

      idx = repository.reload.project_index
      expect(idx.status).to eq('failed')
      expect(idx.error_message).to include('fatal: nope')
    end

    it 'truncates very long error messages to 2000 chars (DB column protection)' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:repository_indexing, anything, lane: :chat).and_return(chat_provider)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_raise(StandardError, 'x' * 5000)

      expect { described_class.new.perform(repository) }.to raise_error(StandardError)
      expect(repository.reload.project_index.error_message.length).to be <= 2000
    end
  end

  describe 'ensure_index' do
    it 'creates a fresh ProjectIndex when none exists' do
      repository.project_index&.destroy
      stub_external!
      expect { described_class.new.perform(repository) }
        .to change { ProjectIndex.where(project_repository: repository).count }.from(0).to(1)
    end

    it 'reuses an existing ProjectIndex (no duplicate)' do
      # Repo callback already created a pending ProjectIndex; the job must reuse it
      _ = repository.project_index # ensure created
      stub_external!
      expect { described_class.new.perform(repository) }
        .not_to change(ProjectIndex, :count)
    end
  end

  describe 'generator call ordering (Vision must run before Capabilities)' do
    # If someone swaps the order in #generate_layer_4_and_3, this fails because
    # CapabilityGenerator's key_modules contract depends on symbols (M6+) that
    # don't exist yet, but Vision is the simpler call and should win first.
    it 'invokes VisionGenerator before CapabilityGenerator' do
      ordered = []
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:repository_indexing, anything, lane: :chat).and_return(chat_provider)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      allow(embed_provider).to receive(:embed).and_return(embedding)
      allow(embed_provider).to receive(:default_embedding_model).and_return('text-embedding-3-small')

      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake'))
      allow(cloner).to receive(:cloned_commit).and_return('a' * 40)
      scanner = instance_double(Lalabase::Indexer::RepoScanner, call: fake_scan)
      allow(Lalabase::Indexer::RepoScanner).to receive(:new).and_return(scanner)

      vision_gen = instance_double(Lalabase::Indexer::VisionGenerator)
      cap_gen    = instance_double(Lalabase::Indexer::CapabilityGenerator)
      allow(Lalabase::Indexer::VisionGenerator).to receive(:new) {
        ordered << :vision
        vision_gen
      }
      allow(Lalabase::Indexer::CapabilityGenerator).to receive(:new) {
        ordered << :capabilities
        cap_gen
      }
      allow(vision_gen).to receive(:call).and_return(vision_result)
      allow(cap_gen).to receive(:call).and_return(capabilities_result)

      described_class.new.perform(repository)
      expect(ordered).to eq(%i[vision capabilities])
    end
  end

  describe 'failure modes inside Layer 4/3 generation' do
    it 'flips to failed when embedding generation raises' do
      stub_external!
      allow(embed_provider).to receive(:embed).and_raise(Lalabase::Llm::Provider::Error, 'embed boom')

      expect { described_class.new.perform(repository) }
        .to raise_error(Lalabase::Llm::Provider::Error)

      expect(repository.reload.project_index.status).to eq('failed')
      expect(repository.reload.project_index.error_message).to include('embed boom')
    end

    it 'flips to failed when VisionGenerator raises (e.g. provider auth)' do
      stub_external!
      bad_vision = instance_double(Lalabase::Indexer::VisionGenerator)
      allow(Lalabase::Indexer::VisionGenerator).to receive(:new).and_return(bad_vision)
      allow(bad_vision).to receive(:call).and_raise(Lalabase::Llm::Provider::AuthError, '401')

      expect { described_class.new.perform(repository) }
        .to raise_error(Lalabase::Llm::Provider::AuthError)
      expect(repository.reload.project_index.status).to eq('failed')
    end

    it 'flips to failed when CapabilityGenerator raises ParseError (vision already persisted is acceptable)' do
      stub_external!
      bad_caps = instance_double(Lalabase::Indexer::CapabilityGenerator)
      allow(Lalabase::Indexer::CapabilityGenerator).to receive(:new).and_return(bad_caps)
      allow(bad_caps).to receive(:call).and_raise(Lalabase::Indexer::CapabilityGenerator::ParseError, 'bad json')

      expect { described_class.new.perform(repository) }
        .to raise_error(Lalabase::Indexer::CapabilityGenerator::ParseError)
      expect(repository.reload.project_index.status).to eq('failed')
    end
  end

  describe 'empty repository (no README, no manifests)' do
    it 'still completes without crashing — generators handle empty scan' do
      empty_scan = { readme: nil, manifests: {}, claude_md: nil, top_level: [], language_hint: nil }
      stub_external!(scan: empty_scan)
      described_class.new.perform(repository)
      expect(repository.reload.project_index.status).to eq('ready')
    end
  end

  describe 'Layer 1 status reflects M6 work (no longer pending after job completes)' do
    # M5 left layer_1_status='pending' because the Layer-1 work didn't exist yet.
    # M6 added the parser-based CodeSymbol extraction, so layer_1_status flips
    # to 'ready' after a successful run, even when the repo has no Ruby files
    # (zero symbols is a valid "done" state).
    before { stub_external! }

    it 'flips layer_1_status to ready (Layer 1 work was actually performed)' do
      described_class.new.perform(repository)
      idx = repository.reload.project_index
      expect(idx.layer_1_status).to eq('ready')
    end
  end

  describe 'token does not leak into error_message or logs from non-GitCloner exceptions' do
    let(:token) { 'ghp_supersecret_in_exception_message' }
    before do
      ActsAsTenant.with_tenant(organisation) do
        repository.update_columns(access_token: token) # bypass encryption changes
      end
      stub_external!
    end

    it 'redacts the access token if a provider error message happens to contain it' do
      allow(embed_provider).to receive(:embed)
        .and_raise(Lalabase::Llm::Provider::Error,
                   "auth failed using token #{token} (please rotate)")
      expect { described_class.new.perform(repository) }
        .to raise_error(Lalabase::Llm::Provider::Error)
      saved = repository.reload.project_index.error_message.to_s
      expect(saved).not_to include(token)
    end

    it 'does NOT leak the token into Rails.logger output (defense in depth)' do
      allow(embed_provider).to receive(:embed)
        .and_raise(Lalabase::Llm::Provider::Error,
                   "auth failed using token #{token} (please rotate)")
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)
      begin
        expect { described_class.new.perform(repository) }
          .to raise_error(Lalabase::Llm::Provider::Error)
      ensure
        Rails.logger = original_logger
      end
      expect(log_output.string).not_to include(token)
    end

    it 'does NOT leak the token in the re-raised exception message' do
      allow(embed_provider).to receive(:embed)
        .and_raise(Lalabase::Llm::Provider::Error,
                   "auth failed using token #{token} (please rotate)")
      raised = begin
        described_class.new.perform(repository)
        nil
      rescue StandardError => e
        e
      end
      expect(raised).not_to be_nil
      expect(raised.message).not_to include(token)
    end
  end

  describe 'duplicate capability names from the LLM must not crash the indexer' do
    # Bug: ProjectCapability has UNIQUE (project_id, name). If the LLM returns two
    # entries called "Notifications", the job currently persists one and crashes on
    # the second → status=failed even though the content was salvageable.
    let(:duped) do
      { capabilities: [
          { name: 'Notifications', description: 'desc1', key_modules: [] },
          { name: 'Notifications', description: 'desc2', key_modules: [] },
          { name: 'Multi-Tenancy', description: 'desc3', key_modules: [] }
        ],
        language: 'en', model_used: 'gpt-4o-mini',
        token_usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } }
    end

    it 'dedupes capabilities by name (first one wins) and completes successfully' do
      stub_external!(capabilities: duped)
      expect { described_class.new.perform(repository) }.not_to raise_error
      expect(repository.reload.project_index.status).to eq('ready')
      names = ProjectCapability.where(project_id: project.id).pluck(:name)
      expect(names).to contain_exactly('Notifications', 'Multi-Tenancy')
    end

    it 'dedupes capabilities case-INSENSITIVELY (LLM mixes "Notifications" + "notifications")' do
      # PG unique index on (project_id, name) is case-sensitive (btree on text),
      # so "Notifications" + "notifications" both succeed → semantic duplicates
      # appear as separate capabilities in the UI. Dedupe by downcased name.
      mixed_case = {
        capabilities: [
          { name: 'Notifications', description: 'desc1', key_modules: [] },
          { name: 'notifications', description: 'desc2', key_modules: [] },
          { name: 'NOTIFICATIONS', description: 'desc3', key_modules: [] }
        ],
        language: 'en', model_used: 'gpt-4o-mini',
        token_usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 }
      }
      stub_external!(capabilities: mixed_case)
      described_class.new.perform(repository)
      names = ProjectCapability.where(project_id: project.id).pluck(:name)
      expect(names.size).to eq(1) # only ONE notifications variant
      expect(names.first.downcase).to eq('notifications')
    end
  end

  describe 'RecordNotFound between enqueue and perform' do
    # If the repo gets deleted while the job is queued, ProjectRepository.find
    # raises. We currently only discard on DeserializationError. Better: discard
    # on RecordNotFound too, so the queue doesn't accumulate stale failures.
    it 'discards the job gracefully when the repository no longer exists' do
      vanished_id = repository.id
      ActsAsTenant.with_tenant(organisation) { repository.destroy! }
      vanished = ProjectRepository.new(id: vanished_id, organisation: organisation)
      allow(vanished).to receive(:organisation).and_return(organisation)
      # perform_now goes through ActiveJob's discard_on machinery; perform directly
      # would bypass it. The "discarded" behaviour we contract is "no raise on the
      # SolidQueue worker".
      expect { described_class.perform_now(vanished) }.not_to raise_error
    end
  end

  describe 'race-condition: concurrent worker wins between existence-check and create' do
    # Two repos of the same project enqueue jobs at roughly the same time. Both
    # pass first_repo_for_project? (no Vision yet), both call create! — the second
    # hits the (project_id) UNIQUE constraint. The job should swallow it.
    it 'swallows RecordNotUnique on Vision and completes successfully' do
      stub_external!
      allow_any_instance_of(ProjectLayer4Vision).to receive(:save!) do
        raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint'
      end
      expect { described_class.new.perform(repository) }.not_to raise_error
      expect(repository.reload.project_index.status).to eq('ready')
      # Orphan-assert (embedding v2 PR 2): Vision + its sidecar are created in ONE
      # transaction with the rescue OUTSIDE, so a rolled-back Vision leaves NO
      # orphaned sidecar row behind.
      expect(ContentEmbedding.where(embeddable_type: 'ProjectLayer4Vision')).to be_empty
    end

    it 'swallows RecordNotUnique on individual Capability inserts (per-name)' do
      stub_external!
      call_count = 0
      allow_any_instance_of(ProjectCapability).to receive(:save!) do |_obj|
        call_count += 1
        # Fail only the second capability — first still persists.
        raise(ActiveRecord::RecordNotUnique, 'duplicate name') if call_count == 2
      end
      expect { described_class.new.perform(repository) }.not_to raise_error
      expect(repository.reload.project_index.status).to eq('ready')
      # Orphan-assert (embedding v2 PR 2): the conflicting capability's per-iteration
      # transaction rolls the capability AND its sidecar back together, so no sidecar
      # row is left pointing at a capability that never persisted.
      orphaned = ContentEmbedding.where(embeddable_type: 'ProjectCapability')
                                 .where.not(embeddable_id: ProjectCapability.select(:id))
      expect(orphaned).to be_empty
    end
  end

  describe 'idempotency (running twice for the same repo)' do
    # If the user manually retries a job (or auto-enqueue fires twice), Layer 4/3
    # must NOT duplicate. The first_repo_for_project? guard provides this — if
    # someone removes it, the second run would try to create a second Vision
    # for the same project_id and hit the DB UNIQUE constraint (loud failure).
    it 'second run does not duplicate Vision or Capabilities' do
      stub_external!
      described_class.new.perform(repository)
      first_vision_count = ProjectLayer4Vision.where(project_id: project.id).count
      first_caps_count   = ProjectCapability.where(project_id: project.id).count

      described_class.new.perform(repository)
      expect(ProjectLayer4Vision.where(project_id: project.id).count).to eq(first_vision_count)
      expect(ProjectCapability.where(project_id: project.id).count).to eq(first_caps_count)
    end
  end

  describe 'tenant isolation during perform' do
    # Catches mutation: someone removes `ActsAsTenant.with_tenant(...)` from perform.
    it 'enters the repository\'s organisation as the tenant for all DB writes' do
      stub_external!
      seen_tenant = nil
      allow(Lalabase::Indexer::GitCloner).to receive(:new) do |_|
        seen_tenant = ActsAsTenant.current_tenant
        cloner = instance_double(Lalabase::Indexer::GitCloner)
        allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake'))
        allow(cloner).to receive(:cloned_commit).and_return('a' * 40)
        cloner
      end

      ActsAsTenant.with_tenant(create(:organisation)) do
        # Run the job while the surrounding tenant is a DIFFERENT org —
        # the job must switch to the repo's own tenant.
        described_class.new.perform(repository)
      end
      expect(seen_tenant).to eq(organisation)
    end
  end

  describe 'Layer 1 (M6 — CodeSymbol indexing)' do
    let(:sym1) do
      { symbol_type: 'class', name: 'Foo', qualified_name: 'Foo', file_path: 'app/foo.rb',
        start_line: 1, end_line: 5, signature: 'class Foo', language: 'ruby', metadata: {} }
    end
    let(:sym2) do
      { symbol_type: 'method', name: 'bar', qualified_name: 'Foo#bar', file_path: 'app/foo.rb',
        start_line: 2, end_line: 4, signature: 'def bar', language: 'ruby', metadata: {} }
    end

    it 'persists CodeSymbols via insert_all (no per-row ActiveRecord callbacks)' do
      stub_external!(layer_1_symbols: [sym1, sym2])
      expect { described_class.new.perform(repository) }
        .to change(CodeSymbol.where(project_repository_id: repository.id), :count).by(2)
    end

    it 'attaches embeddings produced by embed_batch to each symbol' do
      stub_external!(layer_1_symbols: [sym1, sym2])
      described_class.new.perform(repository)
      symbols = CodeSymbol.where(project_repository_id: repository.id)
      rows = ContentEmbedding.where(embeddable_type: 'CodeSymbol', embeddable_id: symbols.ids)
      expect(rows.count).to eq(2)
      expect(rows.map(&:embedding).compact.size).to eq(2)
    end

    it 'records embedding_provider and embedding_model (not chat-model) on each symbol' do
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      symbol = CodeSymbol.where(project_repository_id: repository.id).first
      expect(ContentEmbedding.find_by(embeddable: symbol))
        .to have_attributes(embedding_provider: 'openai', embedding_model: 'text-embedding-3-small')
    end

    it 'updates layer_1_files_total and layer_1_files_done on the index' do
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      idx = repository.reload.project_index
      expect(idx.layer_1_files_total).to eq(1)
      expect(idx.layer_1_files_done).to eq(1)
    end

    it 'flips layer_1_status to ready after successful indexing' do
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      expect(repository.reload.project_index.layer_1_status).to eq('ready')
    end

    it 'survives a repo with zero Ruby files (empty walker)' do
      stub_external!(layer_1_symbols: [])
      expect { described_class.new.perform(repository) }.not_to raise_error
      expect(repository.reload.project_index.status).to eq('ready')
      expect(CodeSymbol.where(project_repository_id: repository.id).count).to eq(0)
    end

    it 'calls embed_batch (not embed) — batched embedding contract' do
      stub_external!(layer_1_symbols: [sym1, sym2])
      expect(embed_provider).to receive(:embed_batch)
        .with(texts: array_including('class Foo', 'def bar'))
        .and_return([embedding, embedding])
      described_class.new.perform(repository)
    end
  end

  describe 'Layer 1 constants locked' do
    it { expect(described_class::LAYER_1_BATCH_SIZE).to eq(100) }
    it { expect(described_class::LAYER_1_PROGRESS_FILES).to eq(10) }
  end

  describe 'Layer 1 batch-flushing behaviour' do
    # These tests exercise the core memory-bounded streaming behaviour. Without
    # them the whole batching loop is just dead code from a test perspective.

    def symbol(idx)
      { symbol_type: 'method', name: "m#{idx}", qualified_name: "Foo#m#{idx}",
        file_path: 'app/foo.rb', start_line: idx, end_line: idx,
        signature: "def m#{idx}", language: 'ruby', metadata: {} }
    end

    def stub_layer_1_only(file_count:, symbols_per_file:)
      stub_index_pipeline!

      walker = instance_double(Lalabase::Indexer::Symbols::Walker)
      allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
      allow(walker).to receive(:file_count).and_return(file_count)
      file_index = 0
      allow(walker).to receive(:each_file_symbols) do |&blk|
        file_count.times do |i|
          syms = (1..symbols_per_file).map { |s| symbol(file_index * symbols_per_file + s) }
          blk.call(syms, "app/file_#{i}.rb")
          file_index += 1
        end
      end
      # embed_batch returns same number of vectors as inputs.
      allow(embed_provider).to receive(:embed_batch) { |texts:| texts.map { embedding } }
    end

    it 'flushes a batch mid-loop when pending_symbols reaches LAYER_1_BATCH_SIZE' do
      # 1 file × 250 symbols → batches: 100, 100, then 50 at end.
      stub_layer_1_only(file_count: 1, symbols_per_file: 250)
      call_count = 0
      allow(embed_provider).to receive(:embed_batch) do |texts:|
        call_count += 1
        texts.map { embedding }
      end
      described_class.new.perform(repository)
      expect(call_count).to eq(3) # 100 + 100 + 50
      expect(CodeSymbol.where(project_repository_id: repository.id).count).to eq(250)
    end

    it 'flushes once at end when pending_symbols never reaches the batch threshold' do
      # 5 files × 1 symbol = 5 total. No mid-loop flush; one final flush.
      stub_layer_1_only(file_count: 5, symbols_per_file: 1)
      call_count = 0
      allow(embed_provider).to receive(:embed_batch) do |texts:|
        call_count += 1
        texts.map { embedding }
      end
      described_class.new.perform(repository)
      expect(call_count).to eq(1)
      expect(CodeSymbol.where(project_repository_id: repository.id).count).to eq(5)
    end

    it 'flushes the exact batch boundary (100 symbols → exactly 1 batch, no remainder)' do
      stub_layer_1_only(file_count: 1, symbols_per_file: 100)
      call_count = 0
      allow(embed_provider).to receive(:embed_batch) do |texts:|
        call_count += 1
        texts.map { embedding }
      end
      described_class.new.perform(repository)
      expect(call_count).to eq(1)
      expect(CodeSymbol.where(project_repository_id: repository.id).count).to eq(100)
    end

    it 'never flushes with an empty texts array (no API call for 0 symbols)' do
      stub_layer_1_only(file_count: 0, symbols_per_file: 0)
      expect(embed_provider).not_to receive(:embed_batch)
      described_class.new.perform(repository)
    end
  end

  describe 'Layer 1 idempotency on re-run (cleanup of existing CodeSymbols)' do
    let(:sym1) do
      { symbol_type: 'class', name: 'Foo', qualified_name: 'Foo', file_path: 'app/foo.rb',
        start_line: 1, end_line: 5, signature: 'class Foo', language: 'ruby', metadata: {} }
    end

    # Bug class: SolidQueue retries the job after a transient failure. Without
    # cleanup, each retry STACKS new CodeSymbols on top of any rows the previous
    # attempt managed to flush. Symbol-counts grow on every failure → wrong
    # search ranking + ballooning DB.
    it 'replaces existing CodeSymbols rather than appending on a second run' do
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      first_count = CodeSymbol.where(project_repository_id: repository.id).count

      # Re-run the job — should NOT double the row count.
      described_class.new.perform(repository)
      second_count = CodeSymbol.where(project_repository_id: repository.id).count
      expect(second_count).to eq(first_count)
    end

    it 'keeps the previous symbols intact when Layer 1 crashes mid-flight (atomicity)' do
      # Bug class: delete_all + insert_all are not atomic — a mid-flight crash
      # (network error in embed_batch) would wipe the old symbols and leave the
      # repo half-indexed. Wrap in transaction so failures roll back to the
      # pre-delete state.
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      pre_crash = CodeSymbol.where(project_repository_id: repository.id).pluck(:name)
      expect(pre_crash).to eq(['Foo'])

      # Second run: simulate embed_batch crash AFTER delete_all.
      sym_new = sym1.merge(name: 'Bar', qualified_name: 'Bar')
      stub_external!(layer_1_symbols: [sym_new])
      allow(embed_provider).to receive(:embed_batch)
        .and_raise(Lalabase::Llm::Provider::Error, 'simulated mid-batch failure')

      expect { described_class.new.perform(repository) }
        .to raise_error(Lalabase::Llm::Provider::Error)

      post_crash = CodeSymbol.where(project_repository_id: repository.id).pluck(:name)
      expect(post_crash).to eq(['Foo']) # old symbols preserved by rollback
    end

    it 'removes symbols that no longer exist in the source on re-index' do
      stub_external!(layer_1_symbols: [sym1])
      described_class.new.perform(repository)
      expect(CodeSymbol.where(project_repository_id: repository.id, name: 'Foo').count).to eq(1)

      # Second run: the source has changed — Foo is gone, Bar appears.
      sym_new = sym1.merge(name: 'Bar', qualified_name: 'Bar')
      stub_external!(layer_1_symbols: [sym_new])
      described_class.new.perform(repository)

      remaining = CodeSymbol.where(project_repository_id: repository.id).pluck(:name)
      expect(remaining).to eq(['Bar'])
    end
  end

  describe 'Layer 1 progress reporting (layer_1_files_done updates)' do
    def symbol(idx)
      { symbol_type: 'method', name: "m#{idx}", qualified_name: "Foo#m#{idx}",
        file_path: 'app/foo.rb', start_line: idx, end_line: idx,
        signature: "def m#{idx}", language: 'ruby', metadata: {} }
    end

    def stub_for_progress(file_count:)
      stub_index_pipeline!
      allow(embed_provider).to receive(:embed_batch) { |texts:| texts.map { embedding } }

      walker = instance_double(Lalabase::Indexer::Symbols::Walker)
      allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
      allow(walker).to receive(:file_count).and_return(file_count)
      allow(walker).to receive(:each_file_symbols) do |&blk|
        file_count.times { |i| blk.call([symbol(i)], "app/file_#{i}.rb") }
      end
    end

    it 'updates layer_1_files_total upfront from walker.file_count' do
      stub_for_progress(file_count: 25)
      described_class.new.perform(repository)
      expect(repository.reload.project_index.layer_1_files_total).to eq(25)
    end

    it 'updates layer_1_files_done after a multiple of LAYER_1_PROGRESS_FILES files' do
      stub_for_progress(file_count: 25)
      # We can't easily inspect the in-flight update_columns calls, but the
      # final value must reflect ALL files processed.
      described_class.new.perform(repository)
      expect(repository.reload.project_index.layer_1_files_done).to eq(25)
    end

    it 'sets layer_1_files_done = layer_1_files_total on success (final write)' do
      stub_for_progress(file_count: 7) # below the 10-progress threshold
      described_class.new.perform(repository)
      idx = repository.reload.project_index
      expect(idx.layer_1_files_done).to eq(idx.layer_1_files_total).and eq(7)
    end
  end

  describe 'index run history (ProjectIndexRun)' do
    let(:sym) do
      { symbol_type: 'class', name: 'Foo', qualified_name: 'Foo', file_path: 'app/foo.rb',
        start_line: 1, end_line: 5, signature: 'class Foo', language: 'ruby', metadata: {} }
    end

    it 'records a successful run with trigger, commit, counts and the connector as triggerer' do
      stub_external!(layer_1_symbols: [sym])

      expect { described_class.new.perform(repository) }
        .to change(ProjectIndexRun, :count).by(1)

      run = ProjectIndexRun.order(:created_at).last
      expect(run).to have_attributes(
        status: 'ready', trigger: 'initial', incremental: false,
        commit_sha: 'a' * 40, files_count: 1, symbols_added: 1,
        # Full index counts the TOTAL added and never tracks removals — the
        # mirror of the incremental run (added/removed = delta). Asserting 0
        # here pins that contrast; a mutation passing a removed count breaks it.
        symbols_removed: 0,
        triggered_by_user_id: repository.connected_by_user_id
      )
      expect(run.duration_seconds).to be >= 0
    end

    # The fix: without persisting the cloned commit, EVERY first push-webhook
    # falls back to a full re-index (RepoReindexJob can't diff a blank baseline).
    it 'persists last_indexed_commit from the clone on the index' do
      stub_external!
      described_class.new.perform(repository)
      expect(repository.reload.project_index.last_indexed_commit).to eq('a' * 40)
    end

    # The run-history error_message is its OWN leak surface (record_index_run has a
    # redaction call-site separate from fail_index!/the index's error_message). Pin
    # the full failed block here: status + trigger + incremental + token redaction.
    it 'records a FAILED run with the token redacted from ITS error_message' do
      repository.update_columns(access_token: 'ghp_secrettoken') # bypass encryption changes
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:repository_indexing, anything, lane: :chat).and_return(chat_provider)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_raise(StandardError, 'boom ghp_secrettoken leaked')

      expect { described_class.new.perform(repository) }.to raise_error(StandardError)

      run = ProjectIndexRun.order(:created_at).last
      expect(run).to have_attributes(status: 'failed', trigger: 'initial', incremental: false)
      expect(run.error_message).to include('[REDACTED]')
      expect(run.error_message).not_to include('ghp_secrettoken')
    end

    it 'records the trigger passed in — push fallback from a webhook (no user)' do
      stub_external!
      described_class.new.perform(repository, trigger: 'push')
      run = ProjectIndexRun.order(:created_at).last
      expect(run.trigger).to eq('push')
      expect(run.triggered_by_user_id).to be_nil
    end
  end

  # Write-both (embedding v2 PR 2): Vision, each Capability and each CodeSymbol get a
  # shadow content_embeddings row; a full re-index purges the repo's OLD symbol
  # sidecar rows (Matrix row 10) instead of leaking orphans on every push.
  describe 'sidecar write-both + full-index replace' do
    let(:one_symbol) do
      [{ symbol_type: 'class', name: 'A', qualified_name: 'A', file_path: 'app/a.rb',
         start_line: 1, end_line: 2, signature: 'class A; end', language: 'ruby', metadata: {} }]
    end

    # The per-record read-back loops below issue repeated SELECTs by design.
    before { Prosopite.pause }

    it 'writes a sidecar row for the vision, each capability and each symbol' do
      stub_external!(layer_1_symbols: one_symbol)
      described_class.new.perform(repository)

      vision = ProjectLayer4Vision.find_by(project: project)
      capability = ProjectCapability.find_by(project: project, name: 'NS')
      symbol = CodeSymbol.find_by(project_repository_id: repository.id)

      { vision => 'A short vision.', capability => 'desc1', symbol => 'class A; end' }.each do |record, text|
        row = ContentEmbedding.find_by(embeddable: record)
        expect(row).to have_attributes(
          embedding_provider: 'openai', embedding_model: 'text-embedding-3-small', embedding_dims: 1536,
          source_hash: ContentEmbedding.source_hash_for(text), indexed: true
        )
      end
    end

    it 'purges the repo\'s previous CodeSymbol sidecar rows on a full re-index (Matrix 10)' do
      stub_external!(layer_1_symbols: one_symbol)
      described_class.new.perform(repository)
      old_symbol = CodeSymbol.find_by(project_repository_id: repository.id)
      old_row = ContentEmbedding.find_by(embeddable: old_symbol)
      expect(old_row).to be_present

      stub_external!(layer_1_symbols: one_symbol) # second full run replaces the symbol set
      described_class.new.perform(repository)

      expect(ContentEmbedding.exists?(old_row.id)).to be(false)
      current_ids = CodeSymbol.where(project_repository_id: repository.id).pluck(:id)
      expect(ContentEmbedding.where(embeddable_type: 'CodeSymbol').pluck(:embeddable_id)).to match_array(current_ids)
    end
  end

  # Dimension parity (embedding v2 PR 7). project_layer4_visions.content_embedding and
  # project_capabilities.description_embedding were typed vector(1536), so a 1024-dim org
  # needed a write guard — without it the whole Layer-4/3 pass died on pgvector's dimension
  # error. Both columns are gone: the vector has exactly one destination now, for every
  # dimension. Vision and Capability are asserted SEPARATELY on purpose — they are two
  # distinct write blocks in this job, and a fix applied to only one of them is a real
  # failure mode (it is how the pair was nearly missed in this PR).
  describe 'across dimensions (non-1536 space)' do
    let(:embedding) { Array.new(1024, 0.1) }
    let(:embed_provider) do
      instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai_compatible',
                                                     default_embedding_model: 'mistral-embed',
                                                     expected_embedding_dims: 1024)
    end

    before do
      stub_external!
      # stub_index_pipeline! re-stubs default_embedding_model for every example —
      # put the 1024 model back on top of it.
      allow(embed_provider).to receive(:default_embedding_model).and_return('mistral-embed')
    end

    it 'persists the Vision with a full 1024 sidecar row' do
      described_class.new.perform(repository)

      vision = ProjectLayer4Vision.find_by(project: project)
      expect(ContentEmbedding.find_by(embeddable: vision))
        .to have_attributes(embedding_dims: 1024, embedding_provider: 'openai_compatible',
                            embedding_model: 'mistral-embed', indexed: true)
    end

    it 'persists Capabilities with full 1024 sidecar rows' do
      described_class.new.perform(repository)

      capability = ProjectCapability.find_by(project: project, name: 'NS')
      expect(ContentEmbedding.find_by(embeddable: capability))
        .to have_attributes(embedding_dims: 1024, embedding_provider: 'openai_compatible',
                            embedding_model: 'mistral-embed', indexed: true)
    end
  end
end
