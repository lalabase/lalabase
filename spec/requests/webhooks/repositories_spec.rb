# frozen_string_literal: true

require 'rails_helper'

# GitHub push-webhook endpoint. Authenticity comes ONLY from the per-repo HMAC
# secret verified over the RAW body; there is no session/CSRF. These specs lock
# the security contract (uniform 401, HMAC really covers the body, no nil-key
# crash) plus the event/branch routing (202 enqueue vs. 204 ignore).
RSpec.describe 'Webhooks::Repositories', :ci_guard, type: :request do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', default_branch: 'main')
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    # Force-create the repo before any expect{} block, then clear the queue, so
    # its after_create_commit indexing enqueue can't pollute the job assertions.
    repository
    clear_enqueued_jobs
  end
  after { ActsAsTenant.current_tenant = nil }

  # --- helpers --------------------------------------------------------------

  def sign(secret, body)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  def push_body(ref: 'refs/heads/main', after: 'abc123def456')
    { ref: ref, after: after, repository: { full_name: 'acme/backend' } }.to_json
  end

  # signature: :valid (HMAC of body with repo secret), :missing (no header), or
  # an explicit string to forge a specific bad/foreign signature.
  def post_webhook(id:, body:, event: 'push', signature: :valid)
    sig = signature == :valid ? sign(repository.webhook_secret, body) : signature
    headers = { 'Content-Type' => 'application/json', 'X-GitHub-Event' => event }
    headers['X-Hub-Signature-256'] = sig unless sig == :missing
    post "/webhooks/repositories/#{id}", params: body, headers: headers
  end

  # --- happy path -----------------------------------------------------------

  context 'valid signature + push on the default branch' do
    let(:body) { push_body(after: 'newhead999') }

    it 'returns 202 accepted' do
      post_webhook(id: repository.id, body: body)
      expect(response).to have_http_status(:accepted)
    end

    it 'enqueues RepoReindexJob with the pushed after-sha' do
      expect { post_webhook(id: repository.id, body: body) }
        .to have_enqueued_job(RepoReindexJob).with(repository, after_sha: 'newhead999')
    end
  end

  # --- signature verification ----------------------------------------------

  context 'invalid signature' do
    it 'returns 401 and enqueues no job' do
      expect { post_webhook(id: repository.id, body: push_body, signature: 'sha256=deadbeef') }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'signature computed with the wrong secret' do
    it 'returns 401 — the HMAC must use THIS repo\'s secret' do
      forged = sign('totally-wrong-secret', push_body)
      post_webhook(id: repository.id, body: push_body, signature: forged)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'signature valid for a DIFFERENT body (tampered payload)' do
    it 'returns 401 — the HMAC covers the raw body, not just header presence' do
      sig_for_other = sign(repository.webhook_secret, push_body(after: 'something-else'))
      post_webhook(id: repository.id, body: push_body(after: 'real-head'), signature: sig_for_other)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'missing signature header' do
    it 'returns 401' do
      post_webhook(id: repository.id, body: push_body, signature: :missing)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'repository without a configured webhook secret (legacy repo)' do
    it 'returns 401 and never crashes on a nil HMAC key' do
      repository.update_column(:webhook_secret, nil)
      post_webhook(id: repository.id, body: push_body, signature: 'sha256=whatever')
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # --- no existence leak ----------------------------------------------------

  context 'unknown repository UUID' do
    let(:ghost) { SecureRandom.uuid }

    it 'returns 401 and enqueues no job even with an otherwise-valid signature' do
      # Signed with the REAL repo's secret, so the 401 can only come from the
      # failed lookup — not from the signature.
      expect { post_webhook(id: ghost, body: push_body) }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'responds identically to an invalid-signature request (no enumeration oracle)' do
      post_webhook(id: ghost, body: push_body, signature: 'sha256=deadbeef')
      not_found = [response.status, response.body.presence]

      post_webhook(id: repository.id, body: push_body, signature: 'sha256=deadbeef')
      bad_signature = [response.status, response.body.presence]

      expect(not_found).to eq(bad_signature)
    end
  end

  # --- event / branch routing (signature already valid) ---------------------

  context 'push on a non-default branch' do
    it 'returns 204 and enqueues no job' do
      feature = push_body(ref: 'refs/heads/feature-x', after: 'abc')
      expect { post_webhook(id: repository.id, body: feature) }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:no_content)
    end
  end

  context 'non-push event (ping)' do
    it 'returns 204 and enqueues no job' do
      ping = { zen: 'Keep it logically awesome.' }.to_json
      expect { post_webhook(id: repository.id, body: ping, event: 'ping') }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:no_content)
    end
  end

  context 'branch deletion (all-zero after-SHA) on the default branch' do
    it 'returns 204 and enqueues no job — nothing to index at a deleted ref' do
      deletion = push_body(after: '0' * 40)
      expect { post_webhook(id: repository.id, body: deletion) }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:no_content)
    end
  end

  context 'push with a blank after-SHA on the default branch' do
    it 'returns 204 and enqueues no job (nothing to index)' do
      blank_after = push_body(after: '')
      expect { post_webhook(id: repository.id, body: blank_after) }
        .not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:no_content)
    end
  end

  # Connected block: a verified push must flow controller → RepoReindexJob →
  # Walker → SymbolPersistence → CodeSymbol, at the EXACT pushed commit. The
  # per-unit specs each mock their neighbour; this runs the real wiring end to
  # end and stubs only the true externals (GitHub Compare / clone / embeddings).
  describe 'end-to-end: a verified push reindexes the changed files' do
    let(:embedding) { Array.new(1536, 0.1) }

    before do
      repository.project_index.update!(status: 'ready', last_indexed_commit: 'base-sha')
      create(:code_symbol, project_repository: repository, organisation: organisation,
                           qualified_name: 'Old::A', file_path: 'app/a.rb')

      github = instance_double(Lalabase::Github::Client)
      allow(Lalabase::Github::Client).to receive(:new).and_return(github)
      allow(github).to receive(:changed_files)
        .and_return([{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }])

      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake-clone'))

      walker = instance_double(Lalabase::Indexer::Symbols::Walker)
      allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
      allow(walker).to receive(:symbols_for).with('app/a.rb').and_return(
        [{ symbol_type: 'class', name: 'New::A', qualified_name: 'New::A', file_path: 'app/a.rb',
           start_line: 1, end_line: 2, signature: 'class New::A; end', language: 'ruby', metadata: {} }]
      )

      embed = instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                             default_embedding_model: 'text-embedding-3-small',
                                                             expected_embedding_dims: 1536)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed)
      allow(embed).to receive(:embed_batch) { |texts:| texts.map { embedding } }
    end

    it 'replaces the changed file’s symbols at the pushed commit and marks the index ready' do
      perform_enqueued_jobs do
        post_webhook(id: repository.id, body: push_body(after: 'deadbeef1234'))
      end

      # The HTTP request clears the thread's tenant; re-establish it to query the
      # tenanted models the job wrote.
      ActsAsTenant.with_tenant(organisation) do
        expect(CodeSymbol.where(project_repository_id: repository.id).pluck(:qualified_name))
          .to contain_exactly('New::A')
        expect(repository.project_index.reload)
          .to have_attributes(status: 'ready', last_indexed_commit: 'deadbeef1234')
      end
      # the C1 guarantee survives the full chain: clone the EXACT pushed sha
      expect(Lalabase::Indexer::GitCloner).to have_received(:new).with(repository, ref: 'deadbeef1234')
    end
  end
end
