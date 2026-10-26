# frozen_string_literal: true

require 'rails_helper'

# What: Unit spec for GoogleVertexProvider (Gemini via Vertex AI, native REST).
# Why (philosophy): This provider is compliance-critical — the REGIONAL
#   endpoint is the GDPR guarantee, service-account auth is what enforces it,
#   and the 1536-truncated embedding is the sovereign lane. The spec pins the
#   wire shapes (verified against the Vertex API reference 2026-07-17) with
#   stubbed HTTP/auth: no live call ever leaves the suite.
# Stubbing style: like the sibling provider specs we stub at the client seam
#   (Faraday connection + googleauth credentials), not at raw Net::HTTP.
RSpec.describe Lalabase::Llm::GoogleVertexProvider do
  let(:connection) { instance_double(Faraday::Connection) }
  let(:fake_creds) do
    instance_double(Google::Auth::ServiceAccountCredentials,
                    access_token: 'oauth-token', fetch_access_token!: nil)
  end
  let(:sa_json) do
    { type: 'service_account', project_id: 'lala-eu',
      private_key: 'PEM', client_email: 'vertex@lala-eu.iam.gserviceaccount.com' }.to_json
  end
  let(:default_config) { { 'project_id' => 'lala-eu', 'location' => 'europe-west3' } }
  let(:provider) { build_provider }
  let(:messages) { [{ role: 'system', content: 'Du bist ein Assistent.' }, { role: 'user', content: 'Hallo' }] }

  # Minimal stand-in for Faraday's request object — the provider only touches
  # headers / params / body / options.on_data.
  let(:request_class) do
    Class.new do
      attr_accessor :body
      attr_reader :headers, :params, :options

      def initialize
        @headers = {}
        @params  = {}
        @options = Struct.new(:on_data).new
      end
    end
  end
  let(:captured) { [] } # [{path:, req:}] of every POST the provider made

  before do
    allow(Faraday).to receive(:new).and_return(connection)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(fake_creds)
    allow(fake_creds).to receive(:expires_within?).and_return(false)
  end

  def build_provider(config: default_config, **kwargs)
    described_class.new(api_key: sa_json, additional_config: config, **kwargs)
  end

  # Stubs connection.post: runs the request-configuration block against a fake
  # request, records it, and returns a canned response.
  def stub_post(status: 200, body: nil)
    allow(connection).to receive(:post) do |path, &block|
      req = request_class.new
      block.call(req)
      captured << { path: path, req: req }
      instance_double(Faraday::Response, status: status, body: body)
    end
  end

  # Streaming variant: feeds the given raw chunks through req.options.on_data
  # (as the Faraday adapter would) before returning the response.
  def stub_stream_post(chunks:, status: 200, env_status: :unset)
    allow(connection).to receive(:post) do |path, &block|
      req = request_class.new
      block.call(req)
      captured << { path: path, req: req }
      # Some Faraday adapters never populate env.status during on_data (nil);
      # env_status drives that path independently of the final response status.
      env = double(status: env_status == :unset ? status : env_status)
      chunks.each { |chunk| req.options.on_data.call(chunk, 0, env) }
      instance_double(Faraday::Response, status: status, body: nil)
    end
  end

  def last_payload
    JSON.parse(captured.last[:req].body)
  end

  def chat_response(parts:, finish_reason: 'STOP', usage: { 'promptTokenCount' => 12, 'candidatesTokenCount' => 4, 'totalTokenCount' => 16 })
    JSON.generate(
      'candidates' => [{ 'content' => { 'role' => 'model', 'parts' => parts }, 'finishReason' => finish_reason }],
      'usageMetadata' => usage
    )
  end

  describe '.provider_name' do
    # Locked as contract: the routing key stays 'google' (NOT the auto-derived
    # 'google_vertex') — it keys the Factory, AiCredential.provider values, the
    # admin dropdown and the org setting.
    it 'is the canonical "google", not the derived "google_vertex"' do
      expect(described_class.provider_name).to eq('google')
      expect(provider.provider_name).to eq('google')
    end
  end

  describe '.supports_embeddings?' do
    it 'is true (the 1536-truncated gemini-embedding-001 is the point of this provider)' do
      expect(described_class.supports_embeddings?).to be(true)
    end
  end

  describe 'model defaults' do
    it 'defaults to the EU-single-region-available chat model' do
      expect(provider.default_chat_model).to eq('gemini-2.5-flash')
      expect(described_class::DEFAULT_CHAT_MODEL).to eq('gemini-2.5-flash')
    end

    it 'honours a configured chat model' do
      expect(build_provider(chat_model: 'gemini-2.5-pro').default_chat_model).to eq('gemini-2.5-pro')
    end

    it 'pins the embedding model constant regardless of configuration (a google credential default_model is its CHAT model)' do
      expect(build_provider(embedding_model: 'gemini-2.0-flash').default_embedding_model).to eq('gemini-embedding-001')
    end
  end

  describe 'configuration fail-fast (GDPR: no implicit endpoint)' do
    before { stub_post(body: chat_response(parts: [{ 'text' => 'x' }])) }

    it 'raises loudly when project_id is missing' do
      p = build_provider(config: { 'location' => 'europe-west3' })
      expect { p.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires additional_config\['project_id'\]/)
    end

    it 'raises loudly when location is missing' do
      p = build_provider(config: { 'project_id' => 'lala-eu' })
      expect { p.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires additional_config\['location'\]/)
    end

    it 'raises loudly when additional_config is nil entirely (e.g. BYOK path)' do
      p = build_provider(config: nil)
      expect { p.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires additional_config/)
    end

    it "rejects location 'global' (would void EU data residency)" do
      p = build_provider(config: { 'project_id' => 'lala-eu', 'location' => 'global' })
      expect { p.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /voids data residency/)
    end

    it 'talks to the REGIONAL endpoint host derived from location' do
      provider.chat(messages: messages)
      expect(Faraday).to have_received(:new)
        .with(hash_including(url: 'https://europe-west3-aiplatform.googleapis.com'))
    end
  end

  describe 'auth' do
    before { stub_post(body: chat_response(parts: [{ 'text' => 'x' }])) }

    it 'mints credentials from the SA JSON with the cloud-platform scope' do
      provider.chat(messages: messages)
      expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds) do |args|
        expect(args[:json_key_io].read).to eq(sa_json)
        expect(args[:scope]).to eq('https://www.googleapis.com/auth/cloud-platform')
      end
    end

    it 'sends the OAuth token as Bearer header' do
      provider.chat(messages: messages)
      expect(captured.last[:req].headers['Authorization']).to eq('Bearer oauth-token')
    end

    it 'fetches a token on first use (none minted yet)' do
      allow(fake_creds).to receive(:access_token).and_return(nil, 'oauth-token')
      provider.chat(messages: messages)
      expect(fake_creds).to have_received(:fetch_access_token!)
    end

    it 're-mints when the token expires within the buffer — per REQUEST, so it cannot lapse mid-stream' do
      allow(fake_creds).to receive(:expires_within?).with(described_class::TOKEN_EXPIRY_BUFFER).and_return(true)
      provider.chat(messages: messages)
      provider.chat(messages: messages)
      expect(fake_creds).to have_received(:fetch_access_token!).twice
    end

    it 'does not re-mint while the token is fresh' do
      provider.chat(messages: messages)
      expect(fake_creds).not_to have_received(:fetch_access_token!)
    end

    it 'maps a Signet authorization failure to AuthError' do
      allow(fake_creds).to receive(:access_token).and_return(nil)
      allow(fake_creds).to receive(:fetch_access_token!).and_raise(Signet::AuthorizationError.new('invalid_grant'))
      expect { provider.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::AuthError, /token mint failed/)
    end

    it 'maps an unparseable SA JSON (legacy AIza key in the column) to AuthError' do
      allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_call_original
      p = described_class.new(api_key: 'AIzaSyLegacyKey123', additional_config: default_config)
      expect { p.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::AuthError, /credentials invalid/)
    end
  end

  describe '#connectivity_check' do
    it 'is true when the token mint round-trips (token-cost-free auth probe)' do
      expect(provider.connectivity_check).to be(true)
    end

    it 'raises AuthError when the mint fails, so the settings button can surface why' do
      allow(fake_creds).to receive(:access_token).and_return(nil)
      allow(fake_creds).to receive(:fetch_access_token!).and_raise(Signet::AuthorizationError.new('denied'))
      expect { provider.connectivity_check }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    # REGRESSION: the probe must run through the CLASS mint, which carries
    # MINT_TIMEOUT_SECONDS and the transport rescue. The memoised instance path
    # (#fresh_access_token) rescues Signet errors ONLY — a hanging auth backend
    # would propagate raw and block a web worker indefinitely instead of
    # failing the button after the timeout.
    it 'maps a hanging auth backend to AuthError (timeout-guarded class mint)' do
      allow(fake_creds).to receive(:fetch_access_token!).and_raise(Timeout::Error)

      expect { provider.connectivity_check }
        .to raise_error(Lalabase::Llm::Provider::AuthError, /transport/)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared class-level auth/endpoint API (consumed by VertexAvailabilityProbe;
  # the instance methods delegate here — pinned independently so the probe's
  # contract cannot drift silently)
  # ---------------------------------------------------------------------------
  describe 'shared class API' do
    describe '.mint_access_token' do
      it 'builds creds from the SA JSON with the cloud-platform scope and returns a one-shot token' do
        expect(described_class.mint_access_token(sa_json)).to eq('oauth-token')
        expect(fake_creds).to have_received(:fetch_access_token!)
        expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds) do |args|
          expect(args[:json_key_io].read).to eq(sa_json)
          expect(args[:scope]).to eq('https://www.googleapis.com/auth/cloud-platform')
        end
      end

      it 'maps a Signet authorization failure to AuthError' do
        allow(fake_creds).to receive(:fetch_access_token!).and_raise(Signet::AuthorizationError.new('invalid_grant'))
        expect { described_class.mint_access_token(sa_json) }
          .to raise_error(Lalabase::Llm::Provider::AuthError, /token mint failed/)
      end

      it 'maps malformed SA JSON to AuthError (ONE creds-builder, one error mapping)' do
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_call_original
        expect { described_class.mint_access_token('AIzaSyLegacyKey123') }
          .to raise_error(Lalabase::Llm::Provider::AuthError, /credentials invalid/)
      end

      it 'never leaks an input fragment (private-key material) into the AuthError on malformed JSON' do
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_call_original
        # A control char inside the private_key value makes the JSON invalid; the
        # raw JSON::ParserError message echoes the input AFTER it — here the fake
        # key tail. The AuthError must carry the generic reason, never that fragment.
        leaky = %({"type":"service_account","private_key":"HEAD\u0001LEAKED_KEY_TAIL","client_email":"x"})
        expect { described_class.mint_access_token(leaky) }.to raise_error(Lalabase::Llm::Provider::AuthError) do |e|
          expect(e.message).to include('malformed JSON')
          expect(e.message).not_to include('LEAKED_KEY_TAIL')
        end
      end

      it 'maps a transport failure (connection refused) to AuthError, not a raw Faraday error' do
        allow(fake_creds).to receive(:fetch_access_token!).and_raise(Faraday::ConnectionFailed.new('refused'))
        expect { described_class.mint_access_token(sa_json) }
          .to raise_error(Lalabase::Llm::Provider::AuthError, /transport/)
      end

      it 'maps a mint timeout to AuthError (no unbounded hang escaping to a 500)' do
        allow(fake_creds).to receive(:fetch_access_token!).and_raise(Timeout::Error)
        expect { described_class.mint_access_token(sa_json) }
          .to raise_error(Lalabase::Llm::Provider::AuthError, /transport/)
      end
    end

    describe '.endpoint_host_for / .model_path_for' do
      it 'pins the endpoint host and model path wire format' do
        expect(described_class.endpoint_host_for('europe-west3'))
          .to eq('https://europe-west3-aiplatform.googleapis.com')
        expect(described_class.model_path_for(project_id: 'lala-eu', location: 'europe-west3',
                                              model: 'gemini-2.5-flash', action: :countTokens))
          .to eq('/v1/projects/lala-eu/locations/europe-west3/publishers/google/models/gemini-2.5-flash:countTokens')
      end

      it "stays UNGATED for 'global' while the instance #location gate keeps raising (deliberate asymmetry)" do
        expect(described_class.endpoint_host_for('global')).to eq('https://global-aiplatform.googleapis.com')
        expect do
          build_provider(config: { 'project_id' => 'lala-eu', 'location' => 'global' }).chat(messages: messages)
        end.to raise_error(Lalabase::Llm::Provider::Error, /voids data residency/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # chat (non-streaming)
  # ---------------------------------------------------------------------------
  describe '#chat' do
    before { stub_post(body: chat_response(parts: [{ 'text' => '  Berlin.  ' }])) }

    it 'posts to the model :generateContent path' do
      provider.chat(messages: messages)
      expect(captured.last[:path])
        .to eq('/v1/projects/lala-eu/locations/europe-west3/publishers/google/models/gemini-2.5-flash:generateContent')
    end

    it 'uses the supplied model in the path when given' do
      provider.chat(messages: messages, model: 'gemini-2.5-pro')
      expect(captured.last[:path]).to include('models/gemini-2.5-pro:generateContent')
    end

    it 'splits the system prompt into systemInstruction and sends user turns as contents' do
      provider.chat(messages: messages)
      expect(last_payload['systemInstruction']).to eq('parts' => [{ 'text' => 'Du bist ein Assistent.' }])
      expect(last_payload['contents']).to eq([{ 'role' => 'user', 'parts' => [{ 'text' => 'Hallo' }] }])
    end

    # Regression (production 2026-08-02): a system-only request produced
    # contents: [] and Vertex answered HTTP 400 "at least one contents field is
    # required" — breaking every summary/analysis feature for orgs routed to
    # Gemini, i.e. exactly the data-sovereignty customers. The instruction IS
    # the request: it becomes the single user content, no systemInstruction.
    it 'folds a system-only request into a single user content (no empty-contents 400)' do
      provider.chat(messages: [{ role: 'system', content: 'Fasse zusammen.' }])
      expect(last_payload['contents']).to eq([{ 'role' => 'user', 'parts' => [{ 'text' => 'Fasse zusammen.' }] }])
      expect(last_payload).not_to have_key('systemInstruction')
    end

    it 'maps assistant turns to role "model"' do
      provider.chat(messages: [{ role: 'user', content: 'Q' }, { role: 'assistant', content: 'A' },
                               { role: 'user', content: 'Q2' }])
      expect(last_payload['contents'].map { |c| c['role'] }).to eq(%w[user model user])
    end

    # max_tokens is the budget of the ANSWER. Gemini 2.5 Flash and Pro think
    # first, and their thought tokens count against maxOutputTokens: with the
    # bare limit a short answer could be left with almost nothing. So these
    # two families get a fixed thinking budget and the same reserve on top.
    describe 'answer budget and thinking reserve' do
      let(:budget) { described_class::THINKING_BUDGET }

      it 'gives the default model (gemini-2.5-flash) a thinking budget and adds it to maxOutputTokens' do
        provider.chat(messages: messages)
        expect(last_payload['generationConfig']).to eq(
          'maxOutputTokens' => 1500 + budget, 'temperature' => 0.7,
          'thinkingConfig' => { 'thinkingBudget' => budget }
        )
      end

      it 'does the same for gemini-2.5-pro, keeping the caller max_tokens as the answer part' do
        provider.chat(messages: messages, model: 'gemini-2.5-pro', max_tokens: 500)
        expect(last_payload['generationConfig']).to eq(
          'maxOutputTokens' => 500 + budget, 'temperature' => 0.7,
          'thinkingConfig' => { 'thinkingBudget' => budget }
        )
      end

      ['gemini-2.5-flash-002', 'gemini-2.5-pro-preview-05-06', 'gemini-2.5-flash-preview-09-2025'].each do |model|
        it "matches the versioned name #{model} of a thinking family" do
          provider.chat(messages: messages, model: model)
          expect(last_payload['generationConfig']).to include('thinkingConfig' => { 'thinkingBudget' => budget })
        end
      end

      it 'keeps the budget inside the range both 2.5 families accept (Pro 128..32768, Flash 1..24576)' do
        expect(budget).to be_between(128, 24_576)
      end

      # Flash-Lite and 2.0 Flash are left exactly as before: a budget would switch
      # thinking ON for Flash-Lite and cost tokens nobody asked for. Gemini 3 takes
      # thinkingLevel instead (thinkingBudget is deprecated there and can 400), and
      # whether its thoughts count against maxOutputTokens is not documented yet.
      # The image, speech and live variants of 2.5 do not think either (a
      # thinkingConfig can be refused there), and a longer word is not the family.
      ['gemini-2.5-flash-lite', 'gemini-2.5-flash-lite-preview-06-17', 'gemini-2.5-flash-image',
       'gemini-2.5-flash-image-preview', 'gemini-2.5-flash-preview-tts', 'gemini-2.5-pro-preview-tts',
       'gemini-2.5-flash-live-preview', 'gemini-2.5-flash-native-audio-dialog', 'gemini-2.5-flashy',
       'gemini-2.0-flash', 'gemini-3-pro-preview', 'gemini-3-flash', 'some-tuned-model']
        .each do |model|
        it "sends #{model} the bare limit, byte for byte as before" do
          provider.chat(messages: messages, model: model)
          expect(last_payload['generationConfig']).to eq('maxOutputTokens' => 1500, 'temperature' => 0.7)
        end
      end

      it 'lets provider_options override the reserve and the thinking config (raw override wins)' do
        provider.chat(messages: messages,
                      provider_options: { maxOutputTokens: 900, thinkingConfig: { thinkingBudget: 0 } })
        expect(last_payload['generationConfig']).to eq(
          'maxOutputTokens' => 900, 'temperature' => 0.7, 'thinkingConfig' => { 'thinkingBudget' => 0 }
        )
      end
    end

    it 'merges provider_options into generationConfig LAST (raw override wins)' do
      provider.chat(messages: messages, temperature: 0.7, provider_options: { temperature: 0.1, topK: 5 })
      expect(last_payload['generationConfig']).to include('temperature' => 0.1, 'topK' => 5)
    end

    it 'returns content stripped and the provider-neutral hash' do
      result = provider.chat(messages: messages)
      expect(result[:content]).to eq('Berlin.')
      expect(result[:model_used]).to eq('gemini-2.5-flash')
      expect(result[:stop_reason]).to eq('stop')
      expect(result[:tool_calls]).to be_nil
    end

    it 'returns the EXACT result hash key set' do
      result = provider.chat(messages: messages)
      expect(result.keys.sort).to eq(%i[content model_used stop_reason token_usage tool_calls].sort)
    end

    it 'maps usageMetadata to the EXACT token_usage key set with real counts' do
      result = provider.chat(messages: messages)
      expect(result[:token_usage]).to include(input_tokens: 12, output_tokens: 4, total_tokens: 16,
                                              estimated: false, cost_cents: 0)
      expect(result[:token_usage].keys.sort).to eq(
        %i[cost_cents duration_ms estimated input_tokens model output_tokens total_tokens].sort
      )
    end

    it 'passes totalTokenCount through even when it exceeds input+output (thinking tokens)' do
      stub_post(body: chat_response(parts: [{ 'text' => 'x' }],
                                    usage: { 'promptTokenCount' => 10, 'candidatesTokenCount' => 5,
                                             'totalTokenCount' => 42 }))
      expect(provider.chat(messages: messages)[:token_usage][:total_tokens]).to eq(42)
    end

    it 'defaults usage to zeros when the response omits usageMetadata' do
      stub_post(body: JSON.generate('candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'x' }] },
                                                       'finishReason' => 'STOP' }]))
      result = provider.chat(messages: messages)
      expect(result[:token_usage]).to include(input_tokens: 0, output_tokens: 0, total_tokens: 0)
    end

    it 'joins multiple text parts' do
      stub_post(body: chat_response(parts: [{ 'text' => 'Hallo ' }, { 'text' => 'Welt' }]))
      expect(provider.chat(messages: messages)[:content]).to eq('Hallo Welt')
    end

    it 'never leaks thought parts (thinking summaries) into content' do
      stub_post(body: chat_response(parts: [{ 'text' => 'internal', 'thought' => true }, { 'text' => 'answer' }]))
      expect(provider.chat(messages: messages)[:content]).to eq('answer')
    end

    it 'raises an explicit Error when candidates are missing (e.g. prompt blocked)' do
      stub_post(body: JSON.generate('candidates' => [], 'promptFeedback' => { 'blockReason' => 'SAFETY' }))
      expect { provider.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /no candidates.*SAFETY/m)
    end

    it 'raises an explicit Error when content is genuinely empty (finishReason in the message)' do
      stub_post(body: chat_response(parts: [], finish_reason: 'MAX_TOKENS'))
      expect { provider.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::Error, /empty content.*MAX_TOKENS/m)
    end

    # Thinking can still spend the whole output limit (the budget is a target, not
    # a hard cap). The empty answer stays an Error for every caller, but a
    # TruncatedError that carries the billed usage, so a caller can meter it and
    # say "cut off" instead of "something went wrong".
    it 'raises TruncatedError carrying stop_reason and usage when MAX_TOKENS left no text' do
      stub_post(body: chat_response(parts: [], finish_reason: 'MAX_TOKENS',
                                    usage: { 'promptTokenCount' => 10, 'candidatesTokenCount' => 0,
                                             'totalTokenCount' => 3558 }))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::TruncatedError) { |error|
        expect(error.result).to include(content: '', stop_reason: 'length', model_used: 'gemini-2.5-flash')
        expect(error.result[:token_usage]).to include(input_tokens: 10, total_tokens: 3558)
      }
    end

    it 'keeps a plain Error (not TruncatedError) for an empty answer that did not hit the limit' do
      stub_post(body: chat_response(parts: [], finish_reason: 'STOP'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::Error) { |error|
        expect(error).not_to be_a(Lalabase::Llm::Provider::TruncatedError)
      }
    end

    it 'returns content_filter (not an error) when an output-side safety block empties the content' do
      # Gemini reports finishReason SAFETY/RECITATION with NO parts on an
      # output-side policy block — surface the contract's content_filter so the
      # Runner can distinguish "policy-blocked" from "genuinely empty".
      stub_post(body: chat_response(parts: [], finish_reason: 'SAFETY'))
      result = provider.chat(messages: messages)
      expect(result[:stop_reason]).to eq('content_filter')
      expect(result[:content]).to eq('')
      expect(result[:tool_calls]).to be_nil
    end

    describe 'stop reason mapping' do
      { 'STOP' => 'stop', 'MAX_TOKENS' => 'length', 'SAFETY' => 'content_filter',
        'RECITATION' => 'content_filter', 'FUTURE_REASON' => 'FUTURE_REASON' }.each do |raw, canonical|
        it "maps finishReason #{raw} → #{canonical}" do
          stub_post(body: chat_response(parts: [{ 'text' => 'x' }], finish_reason: raw))
          expect(provider.chat(messages: messages)[:stop_reason]).to eq(canonical)
        end
      end
    end

    describe 'HTTP error mapping' do
      { 401 => Lalabase::Llm::Provider::AuthError,
        403 => Lalabase::Llm::Provider::AuthError,
        429 => Lalabase::Llm::Provider::RateLimitError }.each do |status, error_class|
        it "maps HTTP #{status} → #{error_class.name.demodulize}" do
          stub_post(status: status, body: '{"error":{"message":"nope"}}')
          expect { provider.chat(messages: messages) }.to raise_error(error_class, /HTTP #{status}.*nope/)
        end
      end

      it 'raises a generic Provider::Error with diagnostics for other statuses' do
        stub_post(status: 500, body: '{"error":{"message":"boom"}}')
        expect { provider.chat(messages: messages) }
          .to raise_error(Lalabase::Llm::Provider::Error, /HTTP 500.*boom/)
      end

      it 'copes with non-JSON error bodies' do
        stub_post(status: 502, body: '<html>Bad Gateway</html>')
        expect { provider.chat(messages: messages) }
          .to raise_error(Lalabase::Llm::Provider::Error, /HTTP 502/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tool-use (functionDeclarations / functionCall / functionResponse)
  # ---------------------------------------------------------------------------
  describe '#chat with tools' do
    let(:tools) do
      [{
        name: 'search_code_symbols',
        description: 'semantic search',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      }]
    end

    it 'sends tools as Gemini functionDeclarations' do
      stub_post(body: chat_response(parts: [{ 'text' => 'ok' }]))
      provider.chat(messages: messages, tools: tools)
      expect(last_payload['tools']).to eq([{
                                            'functionDeclarations' => [{
                                              'name' => 'search_code_symbols',
                                              'description' => 'semantic search',
                                              'parameters' => { 'type' => 'object',
                                                                'properties' => { 'query' => { 'type' => 'string' } },
                                                                'required' => ['query'] }
                                            }]
                                          }])
    end

    # An OBJECT with empty properties is what Gemini's schema subset refuses, and the tool list
    # goes out with every answer: one argument-less tool (help_contents) would fail them all.
    it 'sends a tool without arguments without parameters' do
      stub_post(body: chat_response(parts: [{ 'text' => 'ok' }]))
      tool = { name: 'help_contents', description: 'contents', input_schema: { type: 'object', properties: {} } }

      provider.chat(messages: messages, tools: [tool])

      declaration = last_payload['tools'].first['functionDeclarations'].first
      expect(declaration).to eq('name' => 'help_contents', 'description' => 'contents')
    end

    it 'sends no OBJECT with empty properties for any tool a chat offers' do
      schemas = Lalabase::Tools::Registry::CHAT_SETS.flat_map { |set| Lalabase::Tools::Registry.all_schemas(set: set) }
      declarations = schemas.map { |schema| provider.send(:gemini_function_declaration, schema) }

      empty = declarations.select { |declaration| declaration.key?(:parameters) && declaration[:parameters][:properties].blank? }
      expect(empty.pluck(:name)).to be_empty
      expect(declarations.pluck(:name)).to include('help_contents')
    end

    it 'omits the tools key when tools is nil' do
      stub_post(body: chat_response(parts: [{ 'text' => 'ok' }]))
      provider.chat(messages: messages, tools: nil)
      expect(last_payload).not_to have_key('tools')
    end

    it 'parses functionCall parts into canonical tool_calls with synthesised name-index ids' do
      stub_post(body: chat_response(parts: [
                                      { 'functionCall' => { 'name' => 'search_code_symbols', 'args' => { 'query' => 'auth' } } }
                                    ]))
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls]).to eq([{ id: 'search_code_symbols-0', name: 'search_code_symbols',
                                           args: { 'query' => 'auth' } }])
      expect(result[:content]).to eq('')
    end

    it "derives stop_reason 'tool_calls' from functionCall presence (Gemini reports STOP)" do
      stub_post(body: chat_response(parts: [{ 'functionCall' => { 'name' => 'f', 'args' => {} } }],
                                    finish_reason: 'STOP'))
      expect(provider.chat(messages: messages, tools: tools)[:stop_reason]).to eq('tool_calls')
    end

    it 'parses ALL parallel function calls, same-name calls kept distinct by index' do
      stub_post(body: chat_response(parts: [
                                      { 'functionCall' => { 'name' => 'search_code_symbols', 'args' => { 'query' => 'auth' } } },
                                      { 'functionCall' => { 'name' => 'search_code_symbols', 'args' => { 'query' => 'login' } } }
                                    ]))
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].map { |tc| tc[:id] }).to eq(%w[search_code_symbols-0 search_code_symbols-1])
      expect(result[:tool_calls].map { |tc| tc[:args] }).to eq([{ 'query' => 'auth' }, { 'query' => 'login' }])
    end

    it 'raises on a malformed functionCall without a name (fail fast at the boundary)' do
      stub_post(body: chat_response(parts: [{ 'functionCall' => { 'args' => {} } }]))
      expect { provider.chat(messages: messages, tools: tools) }
        .to raise_error(Lalabase::Llm::Provider::Error, /malformed functionCall/)
    end

    it 'defaults missing/malformed args to {}' do
      stub_post(body: chat_response(parts: [{ 'functionCall' => { 'name' => 'f' } }]))
      expect(provider.chat(messages: messages, tools: tools)[:tool_calls].first[:args]).to eq({})
    end
  end

  describe 'message translation (canonical → Gemini roundtrip)' do
    before { stub_post(body: chat_response(parts: [{ 'text' => 'done' }])) }

    let(:roundtrip_history) do
      [
        { role: 'user', content: 'find auth' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 'search_code_symbols-0', name: 'search_code_symbols', args: { query: 'auth' } }] },
        { role: 'tool', tool_call_id: 'search_code_symbols-0', content: 'no symbols matched' }
      ]
    end

    it 'rewraps an assistant tool_call turn as model/functionCall and the tool result as user/functionResponse' do
      provider.chat(messages: roundtrip_history, tools: nil)
      contents = last_payload['contents']
      expect(contents[1]).to eq(
        'role' => 'model',
        'parts' => [{ 'functionCall' => { 'name' => 'search_code_symbols', 'args' => { 'query' => 'auth' } } }]
      )
      # Gemini has no tool ids — the functionResponse pairs up by NAME, resolved
      # from the preceding assistant turn's id→name map.
      expect(contents[2]).to eq(
        'role' => 'user',
        'parts' => [{ 'functionResponse' => { 'name' => 'search_code_symbols',
                                              'response' => { 'output' => 'no symbols matched' } } }]
      )
    end

    it 'bundles consecutive tool results into ONE user turn (parallel calls, order preserved)' do
      history = [
        { role: 'user', content: 'go' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 'a-0', name: 'a', args: {} }, { id: 'b-1', name: 'b', args: {} }] },
        { role: 'tool', tool_call_id: 'a-0', content: 'ra' },
        { role: 'tool', tool_call_id: 'b-1', content: 'rb' }
      ]
      provider.chat(messages: history)
      contents = last_payload['contents']
      expect(contents.size).to eq(3)
      expect(contents[2]['parts'].map { |p| p['functionResponse']['name'] }).to eq(%w[a b])
    end

    it 'keeps assistant text alongside its functionCalls as a text part' do
      history = [
        { role: 'user', content: 'go' },
        { role: 'assistant', content: 'thinking out loud',
          tool_calls: [{ id: 'a-0', name: 'a', args: {} }] },
        { role: 'tool', tool_call_id: 'a-0', content: 'r' }
      ]
      provider.chat(messages: history)
      expect(last_payload['contents'][1]['parts'].first).to eq('text' => 'thinking out loud')
    end

    it 'passes a Hash tool result through as the functionResponse response object' do
      history = roundtrip_history.tap { |h| h[2] = h[2].merge(content: { rows: 3 }) }
      provider.chat(messages: history)
      expect(last_payload['contents'][2]['parts'].first['functionResponse']['response']).to eq('rows' => 3)
    end

    it "wraps an errored tool result under the 'error' key (Gemini convention, parity with is_error)" do
      history = roundtrip_history.tap { |h| h[2] = h[2].merge(is_error: true) }
      provider.chat(messages: history)
      expect(last_payload['contents'][2]['parts'].first['functionResponse']['response'])
        .to eq('error' => 'no symbols matched')
    end

    it 'raises on an orphan tool message (no preceding assistant-with-tool_calls)' do
      expect { provider.chat(messages: [{ role: 'tool', tool_call_id: 'x-0', content: 'r' }]) }
        .to raise_error(Lalabase::Llm::Provider::Error, %r{orphan/split tool_result at index 0})
    end

    it 'raises on a split bundle (assistant → tool → non-tool → tool)' do
      history = [
        { role: 'assistant', content: nil, tool_calls: [{ id: 'a-0', name: 'a', args: {} }] },
        { role: 'tool', tool_call_id: 'a-0', content: 'r1' },
        { role: 'user', content: 'interruption' },
        { role: 'tool', tool_call_id: 'a-0', content: 'r2' }
      ]
      expect { provider.chat(messages: history) }
        .to raise_error(Lalabase::Llm::Provider::Error, %r{orphan/split tool_result at index 3})
    end

    it 'raises on a tool_call_id with no matching functionCall (the id→name map is the contract)' do
      history = [
        { role: 'assistant', content: nil, tool_calls: [{ id: 'a-0', name: 'a', args: {} }] },
        { role: 'tool', tool_call_id: 'UNKNOWN', content: 'r' }
      ]
      expect { provider.chat(messages: history) }
        .to raise_error(Lalabase::Llm::Provider::Error, /unknown tool_call_id "UNKNOWN"/)
    end

    it 'JSON-encodes Hash content in plain turns instead of Ruby #inspect' do
      provider.chat(messages: [{ role: 'user', content: { a: 1 } }])
      expect(last_payload['contents'].first['parts'].first['text']).to eq('{"a":1}')
    end
  end

  # ---------------------------------------------------------------------------
  # stream_chat (SSE)
  # ---------------------------------------------------------------------------
  describe '#stream_chat' do
    def sse(json_hash)
      "data: #{JSON.generate(json_hash)}\n\n"
    end

    let(:delta_event) { { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'Hel' }] } }] } }
    let(:final_event) do
      { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'lo' }] }, 'finishReason' => 'STOP' }],
        'usageMetadata' => { 'promptTokenCount' => 5, 'candidatesTokenCount' => 2, 'totalTokenCount' => 7 } }
    end

    it 'requires a block' do
      expect { provider.stream_chat(messages: messages) }.to raise_error(ArgumentError, /requires a block/)
    end

    it 'posts to :streamGenerateContent with alt=sse' do
      stub_stream_post(chunks: [sse(delta_event)])
      provider.stream_chat(messages: messages) { |_| }
      expect(captured.last[:path]).to include(':streamGenerateContent')
      expect(captured.last[:req].params['alt']).to eq('sse')
    end

    it 'adds the thinking reserve exactly like #chat (the assistant streams)' do
      stub_stream_post(chunks: [sse(final_event)])
      provider.stream_chat(messages: messages, model: 'gemini-2.5-pro', max_tokens: 1500) { |_| }
      budget = described_class::THINKING_BUDGET
      expect(last_payload['generationConfig']).to eq(
        'maxOutputTokens' => 1500 + budget, 'temperature' => 0.7, 'thinkingConfig' => { 'thinkingBudget' => budget }
      )
    end

    it 'sends a non-thinking model the bare limit when streaming' do
      stub_stream_post(chunks: [sse(final_event)])
      provider.stream_chat(messages: messages, model: 'gemini-2.0-flash') { |_| }
      expect(last_payload['generationConfig']).to eq('maxOutputTokens' => 1500, 'temperature' => 0.7)
    end

    it 'folds a system-only request into a single user content (parity with #chat)' do
      stub_stream_post(chunks: [sse(final_event)])
      provider.stream_chat(messages: [{ role: 'system', content: 'Fasse zusammen.' }]) { |_| }
      expect(last_payload['contents']).to eq([{ 'role' => 'user', 'parts' => [{ 'text' => 'Fasse zusammen.' }] }])
      expect(last_payload).not_to have_key('systemInstruction')
    end

    it 'yields each text delta and returns the accumulated content' do
      stub_stream_post(chunks: [sse(delta_event), sse(final_event)])
      yielded = []
      result = provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(%w[Hel lo])
      expect(result[:content]).to eq('Hello')
    end

    it 'prefers the usageMetadata from the stream over the estimate' do
      stub_stream_post(chunks: [sse(delta_event), sse(final_event)])
      usage = provider.stream_chat(messages: messages) { |_| }[:token_usage]
      expect(usage).to include(input_tokens: 5, output_tokens: 2, total_tokens: 7, estimated: false)
    end

    it 'reassembles an event split across chunk boundaries (buffered SSE parsing)' do
      raw = sse(delta_event)
      stub_stream_post(chunks: [raw[0, 10], raw[10..], sse(final_event)])
      yielded = []
      provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(%w[Hel lo])
    end

    it 'drains deltas even when the adapter leaves env.status nil mid-stream' do
      # Adapters that do not populate env.status during on_data must still get
      # their SSE events drained (the status.nil? branch); the final response
      # status is 200, so nothing is raised. Without that branch this stream
      # would silently yield nothing.
      stub_stream_post(chunks: [sse(delta_event), sse(final_event)], status: 200, env_status: nil)
      yielded = []
      result = provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(%w[Hel lo])
      expect(result[:content]).to eq('Hello')
    end

    it 'processes a final event that arrives without a trailing blank line (tail flush)' do
      stub_stream_post(chunks: [sse(delta_event), "data: #{JSON.generate(final_event)}"])
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:content]).to eq('Hello')
      expect(result[:token_usage][:estimated]).to be(false)
    end

    it 'falls back to a char-based estimate when the stream carries no usageMetadata' do
      stub_stream_post(chunks: [sse(delta_event)])
      usage = provider.stream_chat(messages: messages) { |_| }[:token_usage]
      expect(usage[:estimated]).to be(true)
      expect(usage[:input_tokens]).to be_positive
    end

    it 'returns the EXACT result hash key set' do
      stub_stream_post(chunks: [sse(final_event)])
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result.keys.sort).to eq(%i[content model_used token_usage].sort)
    end

    it 'skips thought parts in deltas' do
      event = { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hidden', 'thought' => true },
                                                              { 'text' => 'shown' }] } }] }
      stub_stream_post(chunks: [sse(event)])
      yielded = []
      provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(['shown'])
    end

    it 'maps a non-200 stream (error body instead of SSE) via the HTTP error mapping' do
      stub_stream_post(chunks: ['{"error":{"message":"quota"}}'], status: 429)
      expect { provider.stream_chat(messages: messages) { |_| } }
        .to raise_error(Lalabase::Llm::Provider::RateLimitError, /quota/)
    end

    it 'raises a diagnostic error on an unparseable SSE data line' do
      stub_stream_post(chunks: ["data: {not json\n\n"])
      expect { provider.stream_chat(messages: messages) { |_| } }
        .to raise_error(Lalabase::Llm::Provider::Error, /unparseable SSE event/)
    end
  end

  # ---------------------------------------------------------------------------
  # embeddings (:predict, default dim 1536)
  # ---------------------------------------------------------------------------
  describe '#embed_with_usage' do
    def predict_body(values:, token_count: 6)
      JSON.generate('predictions' => [{ 'embeddings' => {
                      'values' => values, 'statistics' => { 'token_count' => token_count, 'truncated' => false }
                    } }])
    end

    it 'posts a single instance with outputDimensionality 1536 to the embedding model' do
      stub_post(body: predict_body(values: Array.new(1536, 0.5)))
      provider.embed_with_usage(text: 'hello')
      expect(captured.last[:path]).to include('models/gemini-embedding-001:predict')
      expect(last_payload).to eq(
        'instances' => [{ 'content' => 'hello' }],
        'parameters' => { 'outputDimensionality' => 1536 }
      )
    end

    it 'returns the vector and the token count from the predict statistics' do
      stub_post(body: predict_body(values: Array.new(1536, 0.5), token_count: 9))
      result = provider.embed_with_usage(text: 'hello')
      expect(result[:embedding].length).to eq(1536)
      expect(result[:total_tokens]).to eq(9)
    end

    it 'L2-normalises the truncated vector (gemini-embedding-001 only normalises native 3072 output)' do
      stub_post(body: predict_body(values: Array.new(1536, 0.5)))
      vector = provider.embed_with_usage(text: 'hello')[:embedding]
      norm = Math.sqrt(vector.sum { |v| v * v })
      expect(norm).to be_within(1e-9).of(1.0)
    end

    it 'passes an all-zero vector through unchanged (no NaN from normalising a zero norm)' do
      stub_post(body: predict_body(values: Array.new(1536, 0.0)))
      vector = provider.embed_with_usage(text: 'x')[:embedding]
      expect(vector.length).to eq(1536)
      expect(vector).to all(eq(0.0))
      expect(vector.any? { |v| v.respond_to?(:nan?) && v.nan? }).to be(false)
    end

    # Default-dim boundary (no configured dim → 1536): n-1 / n / n+1 + the
    # native-3072 misconfiguration.
    it 'accepts exactly 1536 dimensions' do
      stub_post(body: predict_body(values: Array.new(1536, 0.1)))
      expect { provider.embed_with_usage(text: 'x') }.not_to raise_error
    end

    [1535, 1537, 3072].each do |dims|
      it "rejects #{dims} dimensions with DimensionMismatchError" do
        stub_post(body: predict_body(values: Array.new(dims, 0.1)))
        expect { provider.embed_with_usage(text: 'x') }
          .to raise_error(Lalabase::Llm::Provider::DimensionMismatchError, /#{dims} dimensions, expected 1536/)
      end
    end

    it 'maps HTTP 401 → AuthError on the embedding path too' do
      stub_post(status: 401, body: '{"error":{"message":"no"}}')
      expect { provider.embed_with_usage(text: 'x') }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end
  end

  describe '#embed' do
    it 'delegates to embed_with_usage and returns only the vector' do
      values = Array.new(1536) { |i| i.zero? ? 1.0 : 0.0 }
      allow(connection).to receive(:post) do |_path, &block|
        block.call(request_class.new)
        instance_double(Faraday::Response, status: 200,
                                           body: JSON.generate('predictions' => [{ 'embeddings' => { 'values' => values, 'statistics' => { 'token_count' => 1 } } }]))
      end
      expect(provider.embed(text: 'x')).to eq(values)
    end
  end

  # ---------------------------------------------------------------------------
  # embeddings with a configured, non-default dimension (v2 §3.2 + m4)
  # ---------------------------------------------------------------------------
  describe '#embed_with_usage with a configured dimension' do
    def predict_body(values:, token_count: 6)
      JSON.generate('predictions' => [{ 'embeddings' => {
                      'values' => values, 'statistics' => { 'token_count' => token_count, 'truncated' => false }
                    } }])
    end

    it 'defaults outputDimensionality to 1536 when no dim is configured (unchanged)' do
      stub_post(body: predict_body(values: Array.new(1536, 0.5)))
      provider.embed_with_usage(text: 'x')
      expect(last_payload['parameters']).to eq('outputDimensionality' => 1536)
    end

    # m4: Vertex only unit-normalises its NATIVE 3072 output; every truncated dim
    # (768/1024/1536) must be normalised client-side, not just the old 1536 path.
    [768, 1024, 1536].each do |dims|
      it "sends outputDimensionality #{dims} and unit-normalises the #{dims}-dim vector" do
        stub_post(body: predict_body(values: Array.new(dims, 0.5)))
        vector = build_provider(embedding_dims: dims).embed_with_usage(text: 'x')[:embedding]

        expect(last_payload['parameters']).to eq('outputDimensionality' => dims)
        expect(vector.length).to eq(dims)
        expect(Math.sqrt(vector.sum { |v| v * v })).to be_within(1e-9).of(1.0)
      end
    end

    it 'rejects a returned vector whose length ≠ the configured dim (guard is the triple)' do
      stub_post(body: predict_body(values: Array.new(1536, 0.5)))
      expect { build_provider(embedding_dims: 768).embed_with_usage(text: 'x') }
        .to raise_error(Lalabase::Llm::Provider::DimensionMismatchError, /1536 dimensions, expected 768/)
    end
  end
end
