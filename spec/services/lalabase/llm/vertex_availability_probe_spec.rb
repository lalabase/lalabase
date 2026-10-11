# frozen_string_literal: true

require 'rails_helper'

# What: Unit spec for VertexAvailabilityProbe (admin matrix region × model via
#   cost-free :countTokens probes).
# Why (philosophy): The matrix is an operator diagnostic — its value hangs on
#   honest status interpretation (200 green / 404 red / rest yellow, plus the
#   ONE embedding asymmetry where 400 means "present", verified live
#   2026-07-18), on per-cell fault isolation, and on never probing when the
#   cache answers. Stubbing style like the sibling google_vertex_provider_spec:
#   Faraday + googleauth are doubled, no live call ever leaves the suite.
# Note on concurrency: MAX_CONCURRENCY is pinned to 1 here because RSpec
#   doubles are not thread-safe under parallel invocation; the pool mechanics
#   (Queue drain, join, combo-ordered results) still execute for real.
RSpec.describe Lalabase::Llm::VertexAvailabilityProbe do
  let(:credential) { create(:ai_credential, :google) } # project 'lala-eu', default_model 'gemini-2.0-flash'
  let(:fake_creds) do
    instance_double(Google::Auth::ServiceAccountCredentials,
                    access_token: 'oauth-token', fetch_access_token!: nil)
  end
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  # Minimal stand-in for Faraday's request object — the probe only touches
  # headers and body.
  let(:request_class) do
    Class.new do
      attr_accessor :body
      attr_reader :headers

      def initialize
        @headers = {}
      end
    end
  end

  # [region, model] → HTTP status Integer, or an exception class to raise as
  # a transport error. Default: every combo answers 200.
  let(:probe_stubs) { Hash.new(200) }
  let(:posted) { [] } # {url:, path:, region:, model:, req:} of every probe POST

  before do
    stub_const('Lalabase::Llm::VertexAvailabilityProbe::MAX_CONCURRENCY', 1)
    # test env runs :null_store — swap in a real store for cache behaviour.
    allow(Rails).to receive(:cache).and_return(memory_store)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(fake_creds)

    allow(Faraday).to receive(:new) do |args|
      url = args[:url]
      region = url[%r{\Ahttps://(.+)-aiplatform\.googleapis\.com\z}, 1]
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:post) do |path, &block|
        req = request_class.new
        block.call(req)
        model = path[%r{models/([^:]+):}, 1]
        posted << { url: url, path: path, region: region, model: model, req: req }
        outcome = probe_stubs[[region, model]]
        raise outcome if outcome.is_a?(Class)

        instance_double(Faraday::Response, status: outcome)
      end
      connection
    end
  end

  def call_probe(force_refresh: true)
    described_class.call(credential_id: credential.id, force_refresh: force_refresh)
  end

  def cell(result, region, model)
    result[:results].find { |r| r[:region] == region && r[:model] == model }
  end

  describe '.call' do
    it 'probes every (region × model) combo via :countTokens with the ping payload and Bearer token' do
      result = call_probe

      # 4 EU regions + global × 5 curated models (factory default_model is in the list)
      expect(result[:regions]).to eq(%w[europe-west1 europe-west3 europe-west4 europe-west9 global])
      expect(result[:models]).to eq(described_class::CANDIDATE_MODELS)
      expect(result[:results].size).to eq(25)
      expect(result[:project_id]).to eq('lala-eu')
      expect(result[:checked_at]).to be_within(5.seconds).of(Time.current)

      expect(cell(result, 'europe-west3', 'gemini-2.5-flash'))
        .to eq(region: 'europe-west3', model: 'gemini-2.5-flash',
               status_code: 200, available: true, info_only: false)

      post = posted.find { |p| p[:region] == 'europe-west3' && p[:model] == 'gemini-2.5-flash' }
      expect(post[:url]).to eq('https://europe-west3-aiplatform.googleapis.com')
      expect(post[:path])
        .to eq('/v1/projects/lala-eu/locations/europe-west3/publishers/google/models/gemini-2.5-flash:countTokens')
      expect(post[:req].headers['Authorization']).to eq('Bearer oauth-token')
      expect(post[:req].headers['Content-Type']).to eq('application/json')
      # The payload is the literal "ping" — no tenant content ever leaves.
      expect(JSON.parse(post[:req].body))
        .to eq('contents' => [{ 'role' => 'user', 'parts' => [{ 'text' => 'ping' }] }])
    end

    it 'marks a 404 combo as unavailable (red)' do
      probe_stubs[%w[europe-west1 gemini-2.0-flash]] = 404

      result = call_probe
      expect(cell(result, 'europe-west1', 'gemini-2.0-flash'))
        .to include(status_code: 404, available: false)
      # neighbours stay green
      expect(cell(result, 'europe-west1', 'gemini-2.5-flash')).to include(available: true)
    end

    it 'keeps other statuses (403/5xx) as yellow cells with the code, without touching the rest' do
      probe_stubs[%w[europe-west4 gemini-2.5-pro]] = 403
      probe_stubs[%w[europe-west9 gemini-2.5-pro]] = 500

      result = call_probe
      expect(cell(result, 'europe-west4', 'gemini-2.5-pro')).to include(status_code: 403, available: false)
      expect(cell(result, 'europe-west9', 'gemini-2.5-pro')).to include(status_code: 500, available: false)
      expect(result[:results].count { |r| r[:available] }).to eq(23)
    end

    it 'treats a 400 on a GENERATIVE model as yellow, not as available (the asymmetry is embedding-only)' do
      probe_stubs[%w[europe-west3 gemini-2.5-flash]] = 400

      expect(cell(call_probe, 'europe-west3', 'gemini-2.5-flash'))
        .to include(status_code: 400, available: false)
    end

    describe 'embedding special rule (countTokens does not apply to embedding models)' do
      it 'counts 400 as AVAILABLE for gemini-embedding-001, keeping the raw status_code for the legend' do
        probe_stubs[%w[europe-west3 gemini-embedding-001]] = 400

        expect(cell(call_probe, 'europe-west3', 'gemini-embedding-001'))
          .to include(status_code: 400, available: true)
      end

      it 'still reads 404 as absent and 429 as yellow for embedding models' do
        probe_stubs[%w[europe-west1 gemini-embedding-001]] = 404
        probe_stubs[%w[europe-west4 gemini-embedding-001]] = 429

        result = call_probe
        expect(cell(result, 'europe-west1', 'gemini-embedding-001')).to include(status_code: 404, available: false)
        expect(cell(result, 'europe-west4', 'gemini-embedding-001')).to include(status_code: 429, available: false)
      end
    end

    it 'isolates a transport failure to its one cell (status_code nil), matrix stays complete' do
      probe_stubs[%w[europe-west9 gemini-2.5-flash]] = Faraday::TimeoutError

      result = call_probe
      expect(cell(result, 'europe-west9', 'gemini-2.5-flash'))
        .to include(status_code: nil, available: false)
      expect(result[:results].size).to eq(25)
      expect(result[:results].count { |r| r[:available] }).to eq(24)
    end

    it 'isolates a NON-Faraday error in one combo (never 500s the whole matrix)' do
      # A per-combo failure outside Faraday::Error (e.g. a bug in path building)
      # must still degrade to a single yellow cell, not propagate out of the pool.
      probe_stubs[%w[europe-west4 gemini-2.5-pro]] = RuntimeError

      result = call_probe
      expect(cell(result, 'europe-west4', 'gemini-2.5-pro'))
        .to include(status_code: nil, available: false)
      expect(result[:results].size).to eq(25)
      expect(result[:results].count { |r| r[:available] }).to eq(24)
    end

    it 'flags global rows as info_only, EU rows not' do
      result = call_probe
      expect(result[:results].select { |r| r[:region] == 'global' }).to all(include(info_only: true))
      expect(result[:results].reject { |r| r[:region] == 'global' }).to all(include(info_only: false))
    end

    it 'serves the cache without any HTTP call unless force_refresh is set' do
      first = call_probe(force_refresh: false)
      posted.clear

      second = call_probe(force_refresh: false)
      expect(posted).to be_empty
      expect(second[:results]).to eq(first[:results])
    end

    it 'force_refresh probes anew and overwrites the cached matrix' do
      call_probe(force_refresh: false)
      probe_stubs[%w[europe-west3 gemini-2.5-flash]] = 404
      posted.clear

      refreshed = call_probe(force_refresh: true)
      expect(posted).not_to be_empty
      expect(cell(refreshed, 'europe-west3', 'gemini-2.5-flash')).to include(available: false)
      # the overwrite is what .cached now serves
      expect(cell(described_class.cached(credential_id: credential.id), 'europe-west3', 'gemini-2.5-flash'))
        .to include(available: false)
    end

    it 'auto-invalidates the cache when the credential is edited (updated_at in the key)' do
      call_probe(force_refresh: false)
      # advance updated_at by a full second — the key truncates to seconds, so
      # a plain touch within the same second would not move it.
      credential.update_column(:updated_at, credential.updated_at + 1.minute)

      expect(described_class.cached(credential_id: credential.id)).to be_nil
    end

    it 'propagates a failing token mint as AuthError — no fan-out, nothing cached' do
      allow(fake_creds).to receive(:fetch_access_token!)
        .and_raise(Signet::AuthorizationError.new('invalid_grant'))

      expect { call_probe }
        .to raise_error(Lalabase::Llm::Provider::AuthError, /token mint failed/)
      expect(posted).to be_empty
      expect(described_class.cached(credential_id: credential.id)).to be_nil
    end

    it 'mints the token exactly ONCE before the fan-out, not per combo' do
      call_probe
      expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds).once
      expect(fake_creds).to have_received(:fetch_access_token!).once
    end

    it 'raises ProbeError for a missing credential' do
      expect { described_class.call(credential_id: SecureRandom.uuid) }
        .to raise_error(described_class::ProbeError, /not found/)
    end

    it 'raises ProbeError for a non-google credential' do
      openai = create(:ai_credential) # provider 'openai'
      expect { described_class.call(credential_id: openai.id) }
        .to raise_error(described_class::ProbeError, /only supports google/)
    end

    it "raises ProbeError when additional_config['project_id'] is missing" do
      credential.update_column(:additional_config, { 'location' => 'europe-west3' })
      expect { call_probe }
        .to raise_error(described_class::ProbeError, /project_id/)
    end

    it 'probes the credential default_model as an extra front column when outside the curated list' do
      credential.update!(default_model: 'gemini-3.0-flash-preview')

      result = call_probe
      expect(result[:models].first).to eq('gemini-3.0-flash-preview')
      expect(result[:models].size).to eq(described_class::CANDIDATE_MODELS.size + 1)
      expect(result[:results].size).to eq(5 * result[:models].size)
      expect(cell(result, 'europe-west3', 'gemini-3.0-flash-preview')).to include(available: true)
    end
  end

  describe '.cached' do
    it 'is a pure cache read — never any HTTP call' do
      expect(described_class.cached(credential_id: credential.id)).to be_nil
      expect(posted).to be_empty
      expect(Faraday).not_to have_received(:new)
    end
  end
end
