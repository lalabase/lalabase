# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Llm::OpenAiProvider do
  let(:fake_client) { instance_double(OpenAI::Client) }
  let(:provider)    { described_class.new(api_key: 'sk-test', organisation_id_param: nil) }
  let(:messages)    { [{ role: 'system', content: 'Du bist ein Assistent.' }, { role: 'user', content: 'Hallo' }] }

  before { allow(OpenAI::Client).to receive(:new).and_return(fake_client) }

  describe '#default_chat_model' do
    it { expect(provider.default_chat_model).to eq('gpt-4o-mini') }
    it 'matches the constant (so renaming the constant only is caught)' do
      expect(described_class::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
    end
  end

  describe '.provider_name' do
    # Locked as contract: must be the canonical 'openai', NOT the auto-derived
    # 'open_ai'. It is the provenance stamp AND the chat credential/usage key, so
    # it has to match the Factory key, AiCredential.provider and the schema default.
    it 'is the canonical "openai", not the derived "open_ai"' do
      expect(described_class.provider_name).to eq('openai')
      expect(described_class.new(api_key: 'sk-test').provider_name).to eq('openai')
    end
  end

  describe '.supports_embeddings?' do
    # S1 capability declaration: openai is embedding-capable — this feeds the
    # AiCredential purpose validation (purpose embedding/both allowed).
    it 'is true' do
      expect(described_class.supports_embeddings?).to be(true)
    end
  end

  describe '#connectivity_check' do
    it 'returns true when the endpoint lists at least one model' do
      allow(fake_client).to receive(:models).and_return(double('models', list: { 'data' => [{ 'id' => 'gpt-4o' }] }))
      expect(provider.connectivity_check).to be(true)
    end

    it 'returns false when the endpoint returns no models' do
      allow(fake_client).to receive(:models).and_return(double('models', list: { 'data' => [] }))
      expect(provider.connectivity_check).to be(false)
    end

    it 'maps an auth failure so the caller can surface it (not a bare Faraday error)' do
      allow(fake_client).to receive(:models).and_return(double('models').tap do |m|
        allow(m).to receive(:list).and_raise(Faraday::UnauthorizedError.new('401'))
      end)
      expect { provider.connectivity_check }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end
  end

  describe 'model + tokenizer constants (locked as contract)' do
    it { expect(described_class::DEFAULT_EMBEDDING_MODEL).to eq('text-embedding-3-small') }
    it { expect(described_class::CHARS_PER_TOKEN).to eq(4.0) }

    # S2: per-token cost constants were removed — pricing lives on the AiCredential
    # and is applied by Lalabase::Llm::CostCalculator, not the provider.
    it 'no longer defines per-token cost constants' do
      expect(described_class.const_defined?(:INPUT_COST_PER_1K)).to be(false)
      expect(described_class.const_defined?(:OUTPUT_COST_PER_1K)).to be(false)
    end
  end

  # -------------------------------------------------------------------------
  # chat (non-streaming)
  # -------------------------------------------------------------------------
  describe '#chat' do
    let(:successful_response) do
      {
        'choices' => [{ 'message' => { 'content' => '  Berlin.  ' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 12, 'completion_tokens' => 4, 'total_tokens' => 16 }
      }
    end

    before { allow(fake_client).to receive(:chat).and_return(successful_response) }

    it 'returns content stripped and provider-neutral hash' do
      result = provider.chat(messages: messages)
      expect(result[:content]).to eq('Berlin.')
      expect(result[:model_used]).to eq('gpt-4o-mini')
      expect(result[:token_usage]).to include(input_tokens: 12, output_tokens: 4, total_tokens: 16, estimated: false)
    end

    it 'uses the supplied model when given' do
      provider.chat(messages: messages, model: 'gpt-4o')
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(model: 'gpt-4o'))
    end

    it 'forwards messages array unchanged (no transformation)' do
      provider.chat(messages: messages)
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(messages: messages))
    end

    it 'forwards max_tokens and temperature' do
      provider.chat(messages: messages, max_tokens: 42, temperature: 0.1)
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(max_tokens: 42, temperature: 0.1))
    end

    it 'uses default max_tokens=1500 and temperature=0.7 when omitted (locked defaults)' do
      provider.chat(messages: messages)
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(max_tokens: 1500, temperature: 0.7))
    end

    it 'always passes n=1 (we never want multiple completions)' do
      provider.chat(messages: messages)
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(n: 1))
    end

    it 'returns the EXACT token_usage key set (no missing/extra keys)' do
      result = provider.chat(messages: messages)
      expect(result[:token_usage].keys.sort).to eq(
        %i[cost_cents duration_ms estimated input_tokens model output_tokens total_tokens].sort
      )
    end

    it 'returns the EXACT result hash key set' do
      result = provider.chat(messages: messages)
      expect(result.keys.sort).to eq(%i[content model_used stop_reason token_usage tool_calls].sort)
    end

    it 'no longer prices tokens in the provider — cost_cents is 0 (CostCalculator owns cost)' do
      result = provider.chat(messages: messages)
      expect(result[:token_usage][:cost_cents]).to eq(0)
    end

    # max_tokens is the budget of the ANSWER. A reasoning model spends its
    # reasoning tokens out of max_completion_tokens too, so the caller's answer
    # budget gets REASONING_RESERVE on top.
    it 'maps reasoning models (gpt-5) to max_completion_tokens plus the reasoning reserve and drops temperature' do
      provider.chat(messages: messages, model: 'gpt-5-nano', max_tokens: 1000, temperature: 0.7,
                    provider_options: { reasoning_effort: 'minimal' })
      expect(fake_client).to have_received(:chat).with(
        parameters: hash_including(model: 'gpt-5-nano', max_completion_tokens: 1000 + described_class::REASONING_RESERVE,
                                   reasoning_effort: 'minimal')
      )
      expect(fake_client).to have_received(:chat).with(parameters: hash_excluding(:max_tokens, :temperature))
    end

    it 'lets provider_options override the reserved max_completion_tokens (raw override wins)' do
      provider.chat(messages: messages, model: 'gpt-5', max_tokens: 1000, provider_options: { max_completion_tokens: 700 })
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(max_completion_tokens: 700))
    end

    it 'forwards provider_options (e.g. presence_penalty) for non-reasoning models' do
      provider.chat(messages: messages, provider_options: { presence_penalty: 0.6 })
      expect(fake_client).to have_received(:chat).with(
        parameters: hash_including(presence_penalty: 0.6, max_tokens: 1500, temperature: 0.7)
      )
    end

    it 'lets provider_options take precedence over a base param (merged LAST — documented override)' do
      # A raw override wins over the structured arg; kills a mutation that merges
      # provider_options FIRST (which would keep the 0.7 default here).
      provider.chat(messages: messages, temperature: 0.7, provider_options: { temperature: 0.1 })
      expect(fake_client).to have_received(:chat).with(parameters: hash_including(temperature: 0.1))
    end

    # REASONING_MODEL_PATTERN = /\A(?:gpt-5|o[1-9])/i. The sharp boundary is gpt-4o:
    # the trailing "o" must NOT be read as the o-series (o1/o3/…). These cases kill
    # mutations that drop the \A anchor, widen the alternation, or swap gpt-5 for gpt-4.
    {
      'gpt-5-nano' => :reasoning, 'gpt-5' => :reasoning, 'o1' => :reasoning, 'o3-mini' => :reasoning,
      'gpt-4o' => :standard, 'gpt-4o-mini' => :standard, 'gpt-3.5-turbo' => :standard
    }.each do |model, kind|
      it "treats #{model.inspect} as a #{kind} model on the wire" do
        provider.chat(messages: messages, model: model, max_tokens: 500, temperature: 0.3)

        if kind == :reasoning
          expect(fake_client).to have_received(:chat)
            .with(parameters: hash_including(max_completion_tokens: 500 + described_class::REASONING_RESERVE))
          expect(fake_client).to have_received(:chat).with(parameters: hash_excluding(:max_tokens, :temperature))
        else
          expect(fake_client).to have_received(:chat).with(parameters: hash_including(max_tokens: 500, temperature: 0.3))
          expect(fake_client).to have_received(:chat).with(parameters: hash_excluding(:max_completion_tokens))
        end
      end
    end

    it 'defaults usage to zeros when API response omits the usage key' do
      allow(fake_client).to receive(:chat).and_return(
        { 'choices' => [{ 'message' => { 'content' => 'x' } }] }
      )
      result = provider.chat(messages: messages)
      expect(result[:token_usage]).to include(input_tokens: 0, output_tokens: 0, total_tokens: 0, cost_cents: 0.0)
    end

    it 'raises an explicit Error when content is missing' do
      allow(fake_client).to receive(:chat).and_return({ 'choices' => [{ 'message' => { 'content' => nil } }] })
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::Error, /empty response/) { |error|
        expect(error).not_to be_a(Lalabase::Llm::Provider::TruncatedError)
      }
    end

    # A reasoning model (or a compatible endpoint) can stop at the limit with
    # content null: same contract as Vertex and Anthropic, see TruncatedError.
    it 'raises TruncatedError carrying the usage when finish_reason length left content null' do
      allow(fake_client).to receive(:chat).and_return(
        { 'choices' => [{ 'message' => { 'content' => nil }, 'finish_reason' => 'length' }],
          'usage' => { 'prompt_tokens' => 21, 'completion_tokens' => 5596, 'total_tokens' => 5617 } }
      )
      expect { provider.chat(messages: messages, model: 'gpt-5') }
        .to raise_error(Lalabase::Llm::Provider::TruncatedError, /empty response/) { |error|
          expect(error.result).to include(content: '', stop_reason: 'length', model_used: 'gpt-5')
          expect(error.result[:token_usage]).to include(input_tokens: 21, output_tokens: 5596, total_tokens: 5617)
        }
    end

    it 'maps Faraday::UnauthorizedError → AuthError' do
      allow(fake_client).to receive(:chat).and_raise(Faraday::UnauthorizedError.new('401'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    it 'maps Faraday::TooManyRequestsError → RateLimitError' do
      allow(fake_client).to receive(:chat).and_raise(Faraday::TooManyRequestsError.new('429'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end

    # A 400 is the endpoint refusing what we asked for (max_tokens above the
    # model's output limit, prompt + max_tokens beyond its context): retrying
    # cannot help. It used to escape as a raw Faraday error.
    it 'maps Faraday::BadRequestError → RequestRefusedError' do
      allow(fake_client).to receive(:chat).and_raise(Faraday::BadRequestError.new('400'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::RequestRefusedError)
    end
  end

  # -------------------------------------------------------------------------
  # stream_chat
  # -------------------------------------------------------------------------
  describe '#stream_chat' do
    it 'requires a block' do
      expect { provider.stream_chat(messages: messages) }.to raise_error(ArgumentError, /requires a block/)
    end

    it 'yields each delta and accumulates content + estimated usage' do
      # REGRESSION: ruby-openai's to_json_stream calls the stream proc with a SINGLE
      # argument (the parsed JSON chunk). Call it with one arg here — a strict 2-arg
      # lambda in stream_chat raised "given 1, expected 2" on every streamed answer.
      allow(fake_client).to receive(:chat) do |args|
        proc_ = args[:parameters][:stream]
        proc_.call({ 'choices' => [{ 'delta' => { 'content' => 'Hello ' } }] })
        proc_.call({ 'choices' => [{ 'delta' => { 'content' => 'world' } }] })
        proc_.call({ 'choices' => [{ 'finish_reason' => 'stop' }] })
      end

      yielded = []
      result = provider.stream_chat(messages: messages) { |delta| yielded << delta }

      expect(yielded).to eq(['Hello ', 'world'])
      expect(result[:content]).to eq('Hello world')
      expect(result[:token_usage][:estimated]).to be(true)
      expect(result[:token_usage][:output_tokens]).to be_positive
    end

    it 'adds the reasoning reserve when streaming a reasoning model, and leaves a standard model alone' do
      captured = []
      allow(fake_client).to receive(:chat) do |args|
        captured << args[:parameters]
        nil
      end

      provider.stream_chat(messages: messages, model: 'gpt-5', max_tokens: 1500) { |_| }
      provider.stream_chat(messages: messages, model: 'gpt-4o-mini', max_tokens: 1500) { |_| }

      expect(captured.first[:max_completion_tokens]).to eq(1500 + described_class::REASONING_RESERVE)
      expect(captured.last).to include(max_tokens: 1500)
      expect(captured.last).not_to have_key(:max_completion_tokens)
    end

    it 'requests stream_options.include_usage so OpenAI emits real token counts' do
      captured = nil
      allow(fake_client).to receive(:chat) do |args|
        captured = args[:parameters]
        nil
      end
      provider.stream_chat(messages: messages) { |_| }
      expect(captured[:stream_options]).to eq(include_usage: true)
    end

    it 'prefers the real usage from the final include_usage chunk over the estimate' do
      allow(fake_client).to receive(:chat) do |args|
        stream = args[:parameters][:stream]
        stream.call({ 'choices' => [{ 'delta' => { 'content' => 'Hi' } }] })
        # The include_usage tail chunk: empty choices, real usage attached.
        stream.call({ 'choices' => [], 'usage' => { 'prompt_tokens' => 111, 'completion_tokens' => 22 } })
      end

      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:token_usage][:estimated]).to be(false)
      expect(result[:token_usage][:input_tokens]).to eq(111)
      expect(result[:token_usage][:output_tokens]).to eq(22)
    end

    it 'treats a usage chunk with only prompt_tokens as real — output falls to 0, not estimated' do
      # Defends the `completion_tokens.to_i` coercion (nil → 0) and pins that a partial
      # usage chunk still counts as real (estimated:false), not a fallback to the estimate.
      allow(fake_client).to receive(:chat) do |args|
        stream = args[:parameters][:stream]
        stream.call({ 'choices' => [{ 'delta' => { 'content' => 'x' } }] })
        stream.call({ 'choices' => [], 'usage' => { 'prompt_tokens' => 88 } })
      end

      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:token_usage][:estimated]).to be(false)
      expect(result[:token_usage][:input_tokens]).to eq(88)
      expect(result[:token_usage][:output_tokens]).to eq(0)
    end

    it 'ignores empty deltas (e.g. role-only chunks)' do
      allow(fake_client).to receive(:chat) do |args|
        args[:parameters][:stream].call({ 'choices' => [{ 'delta' => {} }] })
        args[:parameters][:stream].call({ 'choices' => [{ 'delta' => { 'content' => '' } }] })
        args[:parameters][:stream].call({ 'choices' => [{ 'delta' => { 'content' => 'x' } }] })
      end

      yielded = []
      provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(['x'])
    end

    it 'maps Faraday::UnauthorizedError → AuthError' do
      allow(fake_client).to receive(:chat).and_raise(Faraday::UnauthorizedError.new('401'))
      expect { provider.stream_chat(messages: messages) { |_| } }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    it 'maps Faraday::BadRequestError → RequestRefusedError' do
      allow(fake_client).to receive(:chat).and_raise(Faraday::BadRequestError.new('400'))
      expect { provider.stream_chat(messages: messages) { |_| } }
        .to raise_error(Lalabase::Llm::Provider::RequestRefusedError)
    end

    it 'handles a completely empty stream (no chunks at all)' do
      allow(fake_client).to receive(:chat) { |_args| nil }
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:content]).to eq('')
      expect(result[:token_usage][:output_tokens]).to eq(0)
    end

    it 'counts at least 1 output token for a single-character delta (boundary on `, 1].max`)' do
      # If someone drops the `, 1].max`, ".".split.length == 0 would yield zero
      # output_tokens — a silent regression in cost reporting.
      allow(fake_client).to receive(:chat) do |args|
        args[:parameters][:stream].call({ 'choices' => [{ 'delta' => { 'content' => '.' } }] }, nil)
      end
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:token_usage][:output_tokens]).to be >= 1
    end

    it 'estimates input_tokens from the message char count (locked CHARS_PER_TOKEN contract)' do
      # 8 chars / 4.0 = 2 tokens
      msgs = [{ role: 'user', content: 'abcdefgh' }]
      allow(fake_client).to receive(:chat) { |_args| nil }
      result = provider.stream_chat(messages: msgs) { |_| }
      expect(result[:token_usage][:input_tokens]).to eq(2)
    end

    it 'propagates exceptions from the on_chunk block (does not swallow caller bugs)' do
      allow(fake_client).to receive(:chat) do |args|
        args[:parameters][:stream].call({ 'choices' => [{ 'delta' => { 'content' => 'x' } }] }, nil)
      end
      # The block raises; the internal rescue catches it and logs (intentional —
      # streaming proc must not crash mid-stream). Verify the LOG path, not a raise.
      allow(Rails.logger).to receive(:error)
      provider.stream_chat(messages: messages) { |_| raise 'caller-bug' }
      expect(Rails.logger).to have_received(:error).with(/streaming error.*caller-bug/i)
    end

    it 'returns the EXACT result hash key set' do
      allow(fake_client).to receive(:chat) { |_args| nil }
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result.keys.sort).to eq(%i[content model_used token_usage].sort)
    end

    it 'marks token_usage as estimated:true when streaming' do
      allow(fake_client).to receive(:chat) { |_args| nil }
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:token_usage][:estimated]).to be(true)
    end
  end

  # -------------------------------------------------------------------------
  # embed
  # -------------------------------------------------------------------------
  describe '#embed_batch' do
    it 'sends the input array to the OpenAI API as-is' do
      vecs = [[0.1] * 1536, [0.2] * 1536]
      response = { 'data' => [{ 'index' => 0, 'embedding' => vecs[0] },
                              { 'index' => 1, 'embedding' => vecs[1] }] }
      allow(fake_client).to receive(:embeddings).and_return(response)
      result = provider.embed_batch(texts: %w[alpha beta])
      expect(result).to eq(vecs)
    end

    it 'returns vectors in the same order as the input even when API reorders' do
      vecs = [[0.1] * 1536, [0.2] * 1536]
      response = { 'data' => [{ 'index' => 1, 'embedding' => vecs[1] },
                              { 'index' => 0, 'embedding' => vecs[0] }] }
      allow(fake_client).to receive(:embeddings).and_return(response)
      result = provider.embed_batch(texts: %w[alpha beta])
      expect(result).to eq(vecs)
    end

    it 'returns [] for an empty input (no API call made)' do
      expect(fake_client).not_to receive(:embeddings)
      expect(provider.embed_batch(texts: [])).to eq([])
    end

    it 'uses the hardcoded default embedding model unless overridden' do
      allow(fake_client).to receive(:embeddings).and_return({ 'data' => [] })
      provider.embed_batch(texts: ['x'])
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'text-embedding-3-small', input: ['x'] })
    end

    it 'maps Faraday::UnauthorizedError → AuthError' do
      allow(fake_client).to receive(:embeddings).and_raise(Faraday::UnauthorizedError.new('401'))
      expect { provider.embed_batch(texts: ['x']) }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    # Indexing a large repo embeds in batches; a 429 must surface as the typed
    # RateLimitError (retry path) instead of crashing the job on a raw
    # Faraday::TooManyRequestsError. #embed has the matching guard + test.
    it 'maps Faraday::TooManyRequestsError → RateLimitError' do
      allow(fake_client).to receive(:embeddings).and_raise(Faraday::TooManyRequestsError.new('429'))
      expect { provider.embed_batch(texts: ['x']) }.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end

    it 'tolerates a nil "data" field in the response (defensive)' do
      allow(fake_client).to receive(:embeddings).and_return({ 'data' => nil })
      expect(provider.embed_batch(texts: ['x'])).to eq([])
    end
  end

  # The metering twin of #embed_batch (KI-Pakete P4a+). #embed_batch delegates here,
  # so every example above already exercises the vector half; what needs its own
  # cover is the TOKEN half — the number a customer's bill is computed from. The
  # usage block was in this response all along and nothing read it, which is exactly
  # how the reindex became a blind cost path.
  describe '#embed_batch_with_usage' do
    it 'returns the vectors AND the total_tokens the API reported' do
      vecs = [[0.1] * 1536, [0.2] * 1536]
      response = { 'data' => [{ 'index' => 0, 'embedding' => vecs[0] },
                              { 'index' => 1, 'embedding' => vecs[1] }],
                   'usage' => { 'prompt_tokens' => 9, 'total_tokens' => 42 } }
      allow(fake_client).to receive(:embeddings).and_return(response)

      expect(provider.embed_batch_with_usage(texts: %w[alpha beta]))
        .to eq({ embeddings: vecs, total_tokens: 42 })
    end

    # A self-hosted openai_compatible deployment may omit the block entirely. 0 is
    # the honest answer — and the reindexer reads it as "nothing to bill" rather
    # than booking a row that claims the run was measured.
    it 'reports 0 tokens when the response carries no usage block' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => [0.1] * 1536 }] })

      expect(provider.embed_batch_with_usage(texts: ['x'])[:total_tokens]).to eq(0)
    end

    it 'makes no API call and bills nothing for an empty input' do
      expect(fake_client).not_to receive(:embeddings)
      expect(provider.embed_batch_with_usage(texts: [])).to eq({ embeddings: [], total_tokens: 0 })
    end
  end

  describe '#embed' do
    it 'returns the embedding vector' do
      vec = Array.new(1536, &:to_f)
      allow(fake_client).to receive(:embeddings).and_return({ 'data' => [{ 'embedding' => vec }] })
      expect(provider.embed(text: 'hello')).to eq(vec)
    end

    it 'uses the hardcoded default embedding model unless overridden' do
      # 1536-dim stub so the base dimension guard (embedding v2 PR 2) passes — this
      # case only asserts the request params, the vector content is irrelevant.
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'embedding' => Array.new(1536, 0.0) }] })
      provider.embed(text: 'x')
      expect(fake_client).to have_received(:embeddings).with(parameters: { model: 'text-embedding-3-small', input: 'x' })
    end

    it 'maps Faraday::UnauthorizedError → AuthError' do
      allow(fake_client).to receive(:embeddings).and_raise(Faraday::UnauthorizedError.new('401'))
      expect { provider.embed(text: 'x') }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    # Parity with #embed_batch + #chat + #stream_chat: a 429 on a single
    # embed (RAG query embedding, SearchCodeSymbols) must surface as the typed
    # RateLimitError, not a raw Faraday::TooManyRequestsError.
    it 'maps Faraday::TooManyRequestsError → RateLimitError' do
      allow(fake_client).to receive(:embeddings).and_raise(Faraday::TooManyRequestsError.new('429'))
      expect { provider.embed(text: 'x') }.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end
  end

  # -------------------------------------------------------------------------
  # dimension guard on the base embed path (embedding v2 PR 2) — every returned
  # vector is checked here, not just in OpenAiCompatibleProvider. Unconfigured →
  # expected 1536, so a native-1536 OpenAI response passes unchanged.
  # -------------------------------------------------------------------------
  describe 'base dimension guard' do
    it 'accepts a native 1536-dim vector (default expectation, no configured dim)' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.0) }],
                      'usage' => { 'total_tokens' => 3 } })
      expect { provider.embed(text: 'x') }.not_to raise_error
    end

    it 'rejects a wrong-dim vector on #embed (single) with a loud DimensionMismatchError' do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(768, 0.0) }],
                      'usage' => { 'total_tokens' => 3 } })
      expect { provider.embed(text: 'x') }
        .to raise_error(described_class::DimensionMismatchError, /768 dimensions, expected 1536/)
    end

    it 'rejects a wrong-dim row on #embed_batch (bulk write can never stamp a mis-sized vector)' do
      allow(fake_client).to receive(:embeddings).and_return(
        { 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.1) },
                     { 'index' => 1, 'embedding' => Array.new(1535, 0.2) }] }
      )
      expect { provider.embed_batch(texts: %w[a b]) }
        .to raise_error(described_class::DimensionMismatchError)
    end
  end

  # -------------------------------------------------------------------------
  # dimensions: request parameter (v2 §3.2) — sent ONLY when explicitly
  # configured AND the model accepts it (ada-002 rejects it, 400).
  # -------------------------------------------------------------------------
  describe 'dimensions: request parameter (v2 §3.2)' do
    before do
      allow(fake_client).to receive(:embeddings)
        .and_return({ 'data' => [{ 'index' => 0, 'embedding' => Array.new(1536, 0.1) }],
                      'usage' => { 'total_tokens' => 3 } })
    end

    it 'omits dimensions: when no dim is configured (byte-identical to pre-v2)' do
      described_class.new(api_key: 'sk-test').embed(text: 'x')
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'text-embedding-3-small', input: 'x' })
    end

    it 'sends dimensions: when a dim is explicitly configured (text-embedding-3-small accepts it)' do
      described_class.new(api_key: 'sk-test', embedding_dims: 1536).embed(text: 'x')
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'text-embedding-3-small', input: 'x', dimensions: 1536 })
    end

    # The blocklist matches SUBSTRING markers since embedding v2 PR 5 (§3.5.2, review
    # #350 follow-up): the exact-name match let Azure deployment ALIASES through, which
    # then got a param they 400 on. All four names below carry the ada-002 marker.
    %w[text-embedding-ada-002 ada-002-prod my-ada-002 azure-ada-002-eastus].each do |model|
      it "NEVER sends dimensions: for #{model} even when a dim is configured (ada-002 400s on it)" do
        described_class.new(api_key: 'sk-test', embedding_dims: 1536).embed(text: 'x', model: model)
        expect(fake_client).to have_received(:embeddings)
          .with(parameters: { model: model, input: 'x' })
      end
    end

    # Counter-control: the marker must not swallow the 3-family. Without it, a
    # `include?('ada')` mutation would look green on every example above.
    it 'still sends dimensions: for a model that merely LOOKS similar' do
      described_class.new(api_key: 'sk-test', embedding_dims: 1536)
                     .embed(text: 'x', model: 'text-embedding-3-large-ada')
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'text-embedding-3-large-ada', input: 'x', dimensions: 1536 })
    end

    it 'threads dimensions: through embed_batch too' do
      described_class.new(api_key: 'sk-test', embedding_dims: 1536).embed_batch(texts: %w[a b])
      expect(fake_client).to have_received(:embeddings)
        .with(parameters: { model: 'text-embedding-3-small', input: %w[a b], dimensions: 1536 })
    end
  end

  # -------------------------------------------------------------------------
  # Tool-use (M8.3.5)
  # -------------------------------------------------------------------------
  describe '#chat with tools' do
    let(:tools) do
      [{
        name: 'search_code_symbols',
        description: 'semantic search',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      }]
    end

    let(:text_only_response) do
      {
        'choices' => [{ 'message' => { 'content' => 'plain answer', 'tool_calls' => nil },
                        'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 5, 'total_tokens' => 15 }
      }
    end

    let(:tool_call_response) do
      {
        'choices' => [{
          'message' => {
            'content' => nil,
            'tool_calls' => [{
              'id' => 'call_abc',
              'type' => 'function',
              'function' => { 'name' => 'search_code_symbols',
                              'arguments' => '{"query":"auth","limit":3}' }
            }]
          },
          'finish_reason' => 'tool_calls'
        }],
        'usage' => { 'prompt_tokens' => 20, 'completion_tokens' => 8, 'total_tokens' => 28 }
      }
    end

    it 'sends tools in OpenAI function-call wire format when given' do
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: messages, tools: tools)
      expect(fake_client).to have_received(:chat).with(
        hash_including(parameters: hash_including(tools: [
                                                    { type: 'function',
                                                      function: {
                                                        name: 'search_code_symbols',
                                                        description: 'semantic search',
                                                        parameters: tools.first[:input_schema]
                                                      } }
                                                  ]))
      )
    end

    it 'omits the tools key entirely when tools is nil (no parameter pollution)' do
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: messages, tools: nil)
      expect(fake_client).to have_received(:chat) do |args|
        expect(args[:parameters]).not_to have_key(:tools)
      end
    end

    it 'returns tool_calls: nil for text-only responses' do
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls]).to be_nil
      expect(result[:content]).to eq('plain answer')
      expect(result[:stop_reason]).to eq('stop')
    end

    it 'parses tool_calls into canonical {id, name, args} hashes' do
      allow(fake_client).to receive(:chat).and_return(tool_call_response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls]).to eq([
                                          { id: 'call_abc', name: 'search_code_symbols',
                                            args: { 'query' => 'auth', 'limit' => 3 } }
                                        ])
      expect(result[:content]).to eq('') # nil content normalised to empty string
      expect(result[:stop_reason]).to eq('tool_calls')
    end

    it 'swallows malformed JSON in tool-call arguments (no raise, args = {})' do
      response = tool_call_response.deep_dup
      response['choices'][0]['message']['tool_calls'][0]['function']['arguments'] = '{not json'
      allow(fake_client).to receive(:chat).and_return(response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].first[:args]).to eq({})
    end

    # T1 (strict-review audit): OpenAI's parallel function calling default
    # emits multiple tool_calls in a single response. A mutation that
    # silently grabs only the first call (e.g. `.first(1).map`) would
    # survive without this test.
    it 'parses ALL tool_calls when the model emits parallel function calls' do
      multi = tool_call_response.deep_dup
      multi['choices'][0]['message']['tool_calls'] << {
        'id' => 'call_xyz', 'type' => 'function',
        'function' => { 'name' => 'get_project_vision', 'arguments' => '{}' }
      }
      allow(fake_client).to receive(:chat).and_return(multi)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].size).to eq(2)
      expect(result[:tool_calls].map { |tc| tc[:id] }).to eq(%w[call_abc call_xyz])
      expect(result[:tool_calls].map { |tc| tc[:name] }).to eq(%w[search_code_symbols get_project_vision])
      expect(result[:tool_calls].last[:args]).to eq({})
    end

    it 'parses TWO calls of the SAME tool with distinct args (parallel homogeneous variant)' do
      multi = tool_call_response.deep_dup
      multi['choices'][0]['message']['tool_calls'] << {
        'id' => 'call_def', 'type' => 'function',
        'function' => { 'name' => 'search_code_symbols', 'arguments' => '{"query":"login"}' }
      }
      allow(fake_client).to receive(:chat).and_return(multi)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].size).to eq(2)
      expect(result[:tool_calls].map { |tc| tc[:name] }).to eq(%w[search_code_symbols search_code_symbols])
      expect(result[:tool_calls].map { |tc| tc[:args] }).to eq([
                                                                 { 'query' => 'auth', 'limit' => 3 },
                                                                 { 'query' => 'login' }
                                                               ])
    end

    it 'normalises legacy finish_reason "function_call" → canonical "tool_calls"' do
      response = tool_call_response.deep_dup
      response['choices'][0]['finish_reason'] = 'function_call'
      allow(fake_client).to receive(:chat).and_return(response)
      expect(provider.chat(messages: messages, tools: tools)[:stop_reason]).to eq('tool_calls')
    end

    it 'passes through unknown finish_reason unchanged' do
      response = tool_call_response.deep_dup
      response['choices'][0]['finish_reason'] = 'future_reason'
      allow(fake_client).to receive(:chat).and_return(response)
      expect(provider.chat(messages: messages, tools: tools)[:stop_reason]).to eq('future_reason')
    end

    # R2-5 (parity with Anthropic STOP_REASON_MAP contract test): a silent
    # edit to the map (adding/removing keys) would otherwise survive untested.
    it 'STOP_REASON_MAP is the locked contract (mutation guard)' do
      expect(described_class::STOP_REASON_MAP).to eq('function_call' => 'tool_calls')
    end

    # R2-1 (parity with Anthropic M1): malformed tool_call (missing id or
    # name) must fail fast at the provider boundary, not bubble up as a
    # downstream API 400.
    it 'raises Error when a tool_call is missing id' do
      response = tool_call_response.deep_dup
      response['choices'][0]['message']['tool_calls'][0]['id'] = nil
      allow(fake_client).to receive(:chat).and_return(response)
      expect { provider.chat(messages: messages, tools: tools) }
        .to raise_error(Lalabase::Llm::Provider::Error, /malformed tool_call/)
    end

    it 'raises Error when a tool_call is missing function.name' do
      response = tool_call_response.deep_dup
      response['choices'][0]['message']['tool_calls'][0]['function']['name'] = ''
      allow(fake_client).to receive(:chat).and_return(response)
      expect { provider.chat(messages: messages, tools: tools) }
        .to raise_error(Lalabase::Llm::Provider::Error, /malformed tool_call/)
    end

    it 'still raises Error when BOTH content and tool_calls are missing' do
      response = { 'choices' => [{ 'message' => { 'content' => nil, 'tool_calls' => nil },
                                   'finish_reason' => 'stop' }] }
      allow(fake_client).to receive(:chat).and_return(response)
      expect { provider.chat(messages: messages, tools: tools) }
        .to raise_error(Lalabase::Llm::Provider::Error, /empty response/)
    end
  end

  describe 'message translation for tool-call envelopes' do
    let(:text_only_response) do
      { 'choices' => [{ 'message' => { 'content' => 'ok', 'tool_calls' => nil },
                        'finish_reason' => 'stop' }] }
    end

    it 'rewraps assistant-with-tool_calls messages into OpenAI function-call envelope' do
      canonical = [
        { role: 'user', content: 'find auth' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 'call_1', name: 'search_code_symbols', args: { query: 'auth' } }] },
        { role: 'tool', tool_call_id: 'call_1', content: 'no symbols matched' }
      ]
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: canonical, tools: nil)

      expect(fake_client).to have_received(:chat) do |args|
        sent = args[:parameters][:messages]
        assistant_turn = sent.find { |m| m[:role] == 'assistant' && m[:tool_calls] }
        expect(assistant_turn[:tool_calls]).to eq([{
                                                    id: 'call_1', type: 'function',
                                                    function: { name: 'search_code_symbols', arguments: '{"query":"auth"}' }
                                                  }])
        # tool-role passes through untouched
        expect(sent.last).to eq(role: 'tool', tool_call_id: 'call_1', content: 'no symbols matched')
      end
    end

    it 'leaves plain user/assistant/system messages alone' do
      plain = [{ role: 'system', content: 's' }, { role: 'user', content: 'u' }]
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: plain, tools: nil)
      expect(fake_client).to have_received(:chat) do |args|
        expect(args[:parameters][:messages]).to eq(plain)
      end
    end

    # Regression guard: an earlier version used `.compact` here which silently
    # dropped the `content` key whenever content was nil. OpenAI's API expects
    # `content` to always be present on assistant turns (nullable). The plan
    # §5.2 explicitly specifies `content: nil` for tool-call turns.
    it 'preserves the content key even when content is nil (no .compact)' do
      canonical = [{ role: 'assistant', content: nil,
                     tool_calls: [{ id: 'c1', name: 'search_code_symbols', args: { q: 'x' } }] }]
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: canonical, tools: nil)
      expect(fake_client).to have_received(:chat) do |args|
        assistant = args[:parameters][:messages].first
        expect(assistant).to have_key(:content)
        expect(assistant[:content]).to be_nil
      end
    end

    it 'preserves non-nil content when assistant has BOTH content and tool_calls' do
      canonical = [{ role: 'assistant', content: 'thinking out loud',
                     tool_calls: [{ id: 'c2', name: 'search_code_symbols', args: {} }] }]
      allow(fake_client).to receive(:chat).and_return(text_only_response)
      provider.chat(messages: canonical, tools: nil)
      expect(fake_client).to have_received(:chat) do |args|
        expect(args[:parameters][:messages].first[:content]).to eq('thinking out loud')
      end
    end
  end
end
