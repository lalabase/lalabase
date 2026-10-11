# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Llm::OpenAiCompatibleProvider do
  let(:fake_client) { instance_double(OpenAI::Client) }
  let(:vec1536)     { Array.new(1536, 0.1) }

  def build_provider(api_base: 'https://llm.internal/v1', model: 'bge-1536', key: 'sk-local')
    described_class.new(api_key: key, uri_base: api_base, embedding_model: model)
  end

  describe '.provider_name' do
    it 'is "openai_compatible" so the provenance stamp is honest (not "open_ai")' do
      expect(described_class.provider_name).to eq('openai_compatible')
      expect(build_provider.provider_name).to eq('openai_compatible')
    end
  end

  describe '.supports_embeddings?' do
    # S1 capability declaration: inherited from OpenAiProvider — the dimension
    # guard below (configured dim or default 1536) builds on this capability.
    it 'is true (inherited from OpenAiProvider)' do
      expect(described_class.supports_embeddings?).to be(true)
    end
  end

  describe '#default_embedding_model' do
    it 'returns the configured model' do
      expect(build_provider(model: 'my-embed').default_embedding_model).to eq('my-embed')
    end

    it 'raises when no model is configured (no sane default for an arbitrary endpoint)' do
      expect { build_provider(model: nil).default_embedding_model }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires an embedding model/)
    end
  end

  describe '#client' do
    it 'is built against the configured uri_base' do
      allow(OpenAI::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => vec1536 }] })

      build_provider(api_base: 'https://sovereign.eu/v1').embed(text: 'hi')

      expect(OpenAI::Client).to have_received(:new)
        .with(hash_including(access_token: 'sk-local', uri_base: 'https://sovereign.eu/v1'))
    end

    it 'raises when no api_base is configured (no endpoint to talk to)' do
      expect { build_provider(api_base: nil).embed(text: 'hi') }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires an api_base/)
    end
  end

  describe '#embed' do
    before { allow(OpenAI::Client).to receive(:new).and_return(fake_client) }

    it 'returns the vector and sends the configured model to the endpoint' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => vec1536 }] })

      expect(build_provider(model: 'bge-1536').embed(text: 'hello')).to eq(vec1536)
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'bge-1536', input: 'hello' })
    end

    # Default-dim guard (no configured dim → 1536): boundary n-1 / n / n+1
    it 'accepts exactly 1536 dimensions' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.0) }] })
      expect { build_provider.embed(text: 'x') }.not_to raise_error
    end

    it 'rejects 1535 dimensions' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1535, 0.0) }] })
      expect { build_provider.embed(text: 'x') }
        .to raise_error(described_class::DimensionMismatchError, /1535 dimensions, expected 1536/)
    end

    it 'rejects 1537 dimensions' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1537, 0.0) }] })
      expect { build_provider.embed(text: 'x') }
        .to raise_error(described_class::DimensionMismatchError)
    end
  end

  describe '#embed_batch' do
    before { allow(OpenAI::Client).to receive(:new).and_return(fake_client) }

    it 'returns all vectors when every row is 1536-dim' do
      allow(fake_client).to receive(:embeddings).and_return(
        { 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.1) },
                     { 'index' => 1, 'embedding' => Array.new(1536, 0.2) }] }
      )
      expect(build_provider.embed_batch(texts: %w[a b]).length).to eq(2)
    end

    it 'rejects the batch if any row has the wrong dimension' do
      allow(fake_client).to receive(:embeddings).and_return(
        { 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.1) },
                     { 'index' => 1, 'embedding' => Array.new(768, 0.2) }] }
      )
      expect { build_provider.embed_batch(texts: %w[a b]) }
        .to raise_error(described_class::DimensionMismatchError)
    end
  end

  describe '#default_chat_model (no gpt-4o-mini default)' do
    it 'returns the configured chat model' do
      provider = described_class.new(api_key: 'k', uri_base: 'https://x/v1', chat_model: 'mistral-small')
      expect(provider.default_chat_model).to eq('mistral-small')
    end

    it 'raises when no chat model is configured (unlike the parent OpenAiProvider)' do
      provider = described_class.new(api_key: 'k', uri_base: 'https://x/v1')
      expect { provider.default_chat_model }
        .to raise_error(Lalabase::Llm::Provider::Error, /requires a chat model/)
    end
  end

  describe '#chat (inherited, routed through the configured uri_base)' do
    it 'talks to the configured sovereign endpoint, not api.openai.com' do
      fake = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(fake)
      allow(fake).to receive(:chat).and_return(
        { 'choices' => [{ 'message' => { 'content' => 'hi' }, 'finish_reason' => 'stop' }],
          'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1, 'total_tokens' => 2 } }
      )
      provider = described_class.new(api_key: 'sk-local', uri_base: 'https://sovereign.eu/v1', chat_model: 'local-llm')

      result = provider.chat(messages: [{ role: 'user', content: 'hi' }])

      expect(result[:content]).to eq('hi')
      expect(result[:model_used]).to eq('local-llm')
      expect(OpenAI::Client).to have_received(:new).with(hash_including(uri_base: 'https://sovereign.eu/v1'))
    end
  end

  describe '#connectivity_check (inherited, probes the configured endpoint)' do
    it 'lists models against the configured uri_base, not api.openai.com' do
      fake = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(fake)
      allow(fake).to receive(:models).and_return(double('models', list: { 'data' => [{ 'id' => 'm' }] }))
      provider = described_class.new(api_key: 'k', uri_base: 'https://sovereign.eu/v1', chat_model: 'm')

      expect(provider.connectivity_check).to be(true)
      expect(OpenAI::Client).to have_received(:new).with(hash_including(uri_base: 'https://sovereign.eu/v1'))
    end
  end

  describe 'configured non-1536 dimension (v2 §3.2)' do
    before { allow(OpenAI::Client).to receive(:new).and_return(fake_client) }

    def provider768(additional_config: nil)
      described_class.new(api_key: 'k', uri_base: 'https://llm.internal/v1',
                          embedding_model: 'nomic-768', embedding_dims: 768,
                          additional_config: additional_config)
    end

    it 'accepts a 768-dim vector when embedding_dims is 768' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(768, 0.1) }] })
      expect { provider768.embed(text: 'x') }.not_to raise_error
    end

    it 'rejects a 1536-dim vector when embedding_dims is 768 (the space is the triple)' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.1) }] })
      expect { provider768.embed(text: 'x') }
        .to raise_error(described_class::DimensionMismatchError, /1536 dimensions, expected 768/)
    end

    # The passthrough this spec used to PIN as intended is REVERSED since embedding
    # v2 PR 5 (§3.5.1, review #350 follow-up): this provider talks to Mistral, Ollama,
    # vLLM, LiteLLM, Azure — endpoints that frequently do not know `dimensions:` and
    # answer a 400 to every embed. The PR-5 target case (EU models at their NATIVE
    # dimension) does not need the param at all, so it is off by default and opt-in
    # per credential.
    describe 'the dimensions: request param (default OFF, opt-in per credential)' do
      before do
        allow(fake_client).to receive(:embeddings)
          .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(768, 0.1) }] })
      end

      it 'sends NO dimensions: without the opt-in, even with a dim configured' do
        provider768.embed(text: 'x')
        expect(fake_client).to have_received(:embeddings)
          .with(parameters: { model: 'nomic-768', input: 'x' })
      end

      it 'sends dimensions: when the credential opts in' do
        provider768(additional_config: { 'send_dimensions' => true }).embed(text: 'x')
        expect(fake_client).to have_received(:embeddings)
          .with(parameters: { model: 'nomic-768', input: 'x', dimensions: 768 })
      end

      it 'threads the opt-in through embed_batch too' do
        allow(fake_client).to receive(:embeddings)
          .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(768, 0.1) }] })
        provider768(additional_config: { 'send_dimensions' => true }).embed_batch(texts: ['x'])
        expect(fake_client).to have_received(:embeddings)
          .with(parameters: { model: 'nomic-768', input: ['x'], dimensions: 768 })
      end

      # additional_config is admin-entered, UNVALIDATED JSON that the admin controller
      # permits through a wildcard — the exact channel that was already a P1 in review
      # #350. The flag is therefore parsed STRICTLY boolean, not truthy: a plain
      # `if config['send_dimensions']` would send the param for all three strings
      # below, because they are truthy in Ruby.
      [nil, {}, { 'send_dimensions' => false }, { 'send_dimensions' => 'false' },
       { 'send_dimensions' => '0' }, { 'send_dimensions' => '' },
       { 'send_dimensions' => 0 }, { 'send_dimensions' => nil },
       { 'send_dimensions' => 'off' }, { 'other_key' => true }].each do |config|
        it "sends NO dimensions: for additional_config #{config.inspect}" do
          provider768(additional_config: config).embed(text: 'x')
          expect(fake_client).to have_received(:embeddings)
            .with(parameters: { model: 'nomic-768', input: 'x' })
        end
      end

      [true, 'true', '1', 1, 't', 'on'].each do |value|
        it "sends dimensions: for the boolean-true value #{value.inspect}" do
          provider768(additional_config: { 'send_dimensions' => value }).embed(text: 'x')
          expect(fake_client).to have_received(:embeddings)
            .with(parameters: { model: 'nomic-768', input: 'x', dimensions: 768 })
        end
      end

      # Honest boundary of ActiveModel::Type::Boolean: it recognises a FIXED set of
      # false values ("false", "0", "f", "off", "", 0, false) and reads everything
      # else non-nil as true. A value that is neither — "garbage", but also the
      # plausible-looking "no" — therefore opts IN. Worst case is a loud 400 from the
      # endpoint, never a silent vector-space mix, but it IS the one point where this
      # gate is not strictly fail-closed. Documented here instead of hidden.
      %w[garbage no nein].each do |value|
        it "treats the unrecognised value #{value.inspect} as opt-in (ActiveModel::Type::Boolean contract)" do
          provider768(additional_config: { 'send_dimensions' => value }).embed(text: 'x')
          expect(fake_client).to have_received(:embeddings)
            .with(parameters: { model: 'nomic-768', input: 'x', dimensions: 768 })
        end
      end
    end
  end

  describe 'inheritance' do
    it 'is an OpenAiProvider (shares chat/embed wire format)' do
      expect(described_class.ancestors).to include(Lalabase::Llm::OpenAiProvider)
    end

    it 'DimensionMismatchError is a Provider::Error (single-rescue friendly)' do
      expect(described_class::DimensionMismatchError.ancestors)
        .to include(Lalabase::Llm::Provider::Error)
    end
  end
end
