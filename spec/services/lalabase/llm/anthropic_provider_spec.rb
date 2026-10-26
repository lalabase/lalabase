# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Llm::AnthropicProvider do
  let(:fake_client)   { double('Anthropic::Client') }
  let(:fake_messages) { double('messages-resource') }
  let(:provider)      { described_class.new(api_key: 'sk-ant-test') }
  let(:messages)      do
    [
      { role: 'system', content: 'Du bist ein Assistent.' },
      { role: 'user',   content: 'Hallo' }
    ]
  end

  before do
    allow(Anthropic::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:messages).and_return(fake_messages)
  end

  def text_block(text)
    Struct.new(:type, :text).new(:text, text)
  end

  def usage(input: 10, output: 5)
    Struct.new(:input_tokens, :output_tokens).new(input, output)
  end

  # The Anthropic gem's APIStatusError subclasses require many keyword args via
  # their constructor (url:, status:, headers:, body:, request:, response:).
  # In tests we just need an instance of the right class to be raised — allocate
  # bypasses the constructor entirely.
  def anthropic_error(klass, msg)
    klass.allocate.tap do |e|
      e.define_singleton_method(:message) { msg }
    end
  end

  describe '.provider_name' do
    it { expect(described_class.provider_name).to eq('anthropic') }
  end

  describe '.supports_embeddings?' do
    # S1 capability declaration: Anthropic has no embedding model — this keeps
    # AiCredential purpose embedding/both unselectable for anthropic instead of
    # failing at runtime with NotSupportedError.
    it 'is false' do
      expect(described_class.supports_embeddings?).to be(false)
    end
  end

  describe '#default_chat_model' do
    # Locked to the exact value — a loose `start_with` would let a typo or stale model
    # ID slip through unnoticed.
    it { expect(provider.default_chat_model).to eq('claude-haiku-4-5-20251001') }
    it { expect(described_class::DEFAULT_CHAT_MODEL).to eq('claude-haiku-4-5-20251001') }

    it 'returns the Factory-configured chat_model over the constant (model precedence)' do
      expect(described_class.new(api_key: 'k', chat_model: 'claude-opus-4-7').default_chat_model)
        .to eq('claude-opus-4-7')
    end

    it 'falls back to the constant when no chat_model is configured' do
      expect(described_class.new(api_key: 'k', chat_model: nil).default_chat_model)
        .to eq('claude-haiku-4-5-20251001')
    end
  end

  describe '#connectivity_check' do
    let(:fake_models) { double('models-resource') }

    before { allow(fake_client).to receive(:models).and_return(fake_models) }

    # This was `api_key.present?` with a comment claiming no cheap endpoint
    # existed. GET /v1/models is exactly that: no inference tokens, and an
    # invalid key answers 401 rather than an empty 200 — so a round-trip
    # without an error IS the signal.
    it 'lists models with an explicit timeout and reports success' do
      expect(fake_models).to receive(:list)
        .with(limit: 1, request_options: { timeout: described_class::PROBE_TIMEOUT_SECONDS })

      expect(provider.connectivity_check).to be(true)
    end

    # REGRESSION: any non-empty token used to test green here, so the admin
    # button reported success for a credential that could not connect at all.
    it 'maps an authentication failure to AuthError instead of reporting success' do
      allow(fake_models).to receive(:list)
        .and_raise(anthropic_error(Anthropic::Errors::AuthenticationError, '401'))

      expect { provider.connectivity_check }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    it 'maps a rate-limit failure to RateLimitError' do
      allow(fake_models).to receive(:list)
        .and_raise(anthropic_error(Anthropic::Errors::RateLimitError, '429'))

      expect { provider.connectivity_check }.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end
  end

  describe 'cost constants' do
    # S2: per-token cost constants were removed — pricing lives on the AiCredential
    # and is applied by Lalabase::Llm::CostCalculator, not the provider.
    it 'no longer defines per-token cost constants' do
      expect(described_class.const_defined?(:INPUT_COST_PER_1K)).to be(false)
      expect(described_class.const_defined?(:OUTPUT_COST_PER_1K)).to be(false)
    end
  end

  # -------------------------------------------------------------------------
  # chat (non-streaming) — Anthropic-specific message shape (system separate)
  # -------------------------------------------------------------------------
  describe '#chat' do
    let(:response) do
      Struct.new(:content, :usage).new([text_block('Berlin.')], usage(input: 12, output: 4))
    end

    before { allow(fake_messages).to receive(:create).and_return(response) }

    it 'returns provider-neutral hash with content + token_usage' do
      result = provider.chat(messages: messages)
      expect(result[:content]).to eq('Berlin.')
      expect(result[:token_usage]).to include(input_tokens: 12, output_tokens: 4, total_tokens: 16, estimated: false)
    end

    it 'accepts nil tools (no behaviour change for non-tool callers)' do
      expect { provider.chat(messages: messages, tools: nil) }.not_to raise_error
    end

    it 'lifts system messages into the `system_` param (Anthropic API shape)' do
      provider.chat(messages: messages)
      expect(fake_messages).to have_received(:create).with(hash_including(
                                                             system_: 'Du bist ein Assistent.',
                                                             messages: [{ role: 'user', content: 'Hallo' }]
                                                           ))
    end

    it 'omits `system_` when no system message provided' do
      provider.chat(messages: [{ role: 'user', content: 'Hi' }])
      expect(fake_messages).to have_received(:create).with(satisfy { |params| !params.key?(:system_) })
    end

    it 'joins multiple system messages with double-newline before passing to API' do
      provider.chat(messages: [
                      { role: 'system', content: 'A' },
                      { role: 'system', content: 'B' },
                      { role: 'user',   content: 'Hi' }
                    ])
      expect(fake_messages).to have_received(:create).with(hash_including(system_: "A\n\nB"))
    end

    # Regression: a system-only request (the whole prompt in the system field, no
    # user turn — the shape of the meeting/document summary services) used to
    # reach the API as messages: [] and 400. The instruction IS the request, so
    # it must arrive as the single user turn, with no system param at all.
    it 'folds a system-only request into a single user turn (no empty-messages 400)' do
      provider.chat(messages: [{ role: 'system', content: 'Fasse zusammen.' }])
      expect(fake_messages).to have_received(:create).with(
        satisfy do |params|
          params[:messages] == [{ role: 'user', content: 'Fasse zusammen.' }] && !params.key?(:system_)
        end
      )
    end

    it 'joins multiple system-only messages into ONE folded user turn' do
      provider.chat(messages: [{ role: 'system', content: 'A' }, { role: 'system', content: 'B' }])
      expect(fake_messages).to have_received(:create).with(
        satisfy do |params|
          params[:messages] == [{ role: 'user', content: "A\n\nB" }] && !params.key?(:system_)
        end
      )
    end

    it 'uses the supplied model when given' do
      provider.chat(messages: messages, model: 'claude-opus-4-7')
      expect(fake_messages).to have_received(:create).with(hash_including(model: 'claude-opus-4-7'))
    end

    it 'forwards max_tokens and temperature' do
      provider.chat(messages: messages, max_tokens: 42, temperature: 0.1)
      expect(fake_messages).to have_received(:create).with(hash_including(max_tokens: 42, temperature: 0.1))
    end

    it 'passes provider_options through to the Anthropic params (e.g. top_p)' do
      # Anthropic-appropriate extras must reach the API; kills a mutation dropping the
      # provider_options merge in build_params.
      provider.chat(messages: messages, provider_options: { top_p: 0.9 })
      expect(fake_messages).to have_received(:create).with(hash_including(top_p: 0.9))
    end

    it 'uses default max_tokens=1500 and temperature=0.7 when omitted (locked defaults)' do
      provider.chat(messages: messages)
      expect(fake_messages).to have_received(:create).with(hash_including(max_tokens: 1500, temperature: 0.7))
    end

    it 'preserves user/assistant ordering when stripping system messages' do
      provider.chat(messages: [
                      { role: 'user',      content: 'first user' },
                      { role: 'system',    content: 'mid system' },
                      { role: 'assistant', content: 'mid assistant' },
                      { role: 'user',      content: 'last user' }
                    ])
      expect(fake_messages).to have_received(:create).with(hash_including(
                                                             system_: 'mid system',
                                                             messages: [
                                                               { role: 'user',      content: 'first user' },
                                                               { role: 'assistant', content: 'mid assistant' },
                                                               { role: 'user',      content: 'last user' }
                                                             ]
                                                           ))
    end

    it 'accepts symbol role keys equally to strings (provider-neutral input contract)' do
      provider.chat(messages: [{ role: :system, content: 'S' }, { role: :user, content: 'U' }])
      expect(fake_messages).to have_received(:create).with(hash_including(system_: 'S'))
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
      expect(described_class.const_defined?(:INPUT_COST_PER_1K)).to be(false)
    end

    it 'defaults token_usage to zeros when response has no usage information' do
      no_usage = Struct.new(:content, :usage).new([text_block('x')], nil)
      allow(fake_messages).to receive(:create).and_return(no_usage)
      result = provider.chat(messages: messages)
      expect(result[:token_usage]).to include(input_tokens: 0, output_tokens: 0, total_tokens: 0)
    end

    it 'raises Error when content blocks contain no text' do
      empty_response = Struct.new(:content, :usage).new([], usage)
      allow(fake_messages).to receive(:create).and_return(empty_response)
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::Error, /empty content/) { |error|
        expect(error).not_to be_a(Lalabase::Llm::Provider::TruncatedError)
      }
    end

    # The SDK reports stop_reason as a Symbol; a String is accepted as well.
    [:max_tokens, 'max_tokens'].each do |stop_reason|
      it "raises TruncatedError carrying the real usage when #{stop_reason.inspect} stopped it before any text" do
        cut_response = Struct.new(:content, :usage, :stop_reason).new([], usage(input: 37, output: 0), stop_reason)
        allow(fake_messages).to receive(:create).and_return(cut_response)
        expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::TruncatedError) { |error|
          expect(error.result).to include(content: '', stop_reason: 'length')
          expect(error.result[:token_usage]).to include(input_tokens: 37, output_tokens: 0, total_tokens: 37)
        }
      end
    end

    it 'maps Anthropic::Errors::AuthenticationError → AuthError' do
      allow(fake_messages).to receive(:create).and_raise(anthropic_error(Anthropic::Errors::AuthenticationError, '401'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    it 'maps Anthropic::Errors::RateLimitError → RateLimitError' do
      allow(fake_messages).to receive(:create).and_raise(anthropic_error(Anthropic::Errors::RateLimitError, '429'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end

    # The message is the one prod answered on 2026-08-06 with an exhausted prepaid
    # balance. Before the mapping this class travelled past every provider rescue in
    # ChatResponseJob into its StandardError arm, and the member was told an
    # "unexpected error" had occurred.
    it 'maps a refused request (400) → RequestRefusedError' do
      allow(fake_messages).to receive(:create).and_raise(
        anthropic_error(Anthropic::Errors::BadRequestError,
                        'Your credit balance is too low to access the Anthropic API.')
      )
      expect { provider.chat(messages: messages) }
        .to raise_error(Lalabase::Llm::Provider::RequestRefusedError, /credit balance/)
    end

    it 'maps an inaccessible model (404) → RequestRefusedError' do
      allow(fake_messages).to receive(:create).and_raise(anthropic_error(Anthropic::Errors::NotFoundError, '404'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::RequestRefusedError)
    end

    # The boundary that carries the distinction: 5xx is transient, so it must NOT
    # become the class whose copy tells the reader that waiting cannot help.
    it 'maps a 5xx → Error, not RequestRefusedError' do
      allow(fake_messages).to receive(:create).and_raise(anthropic_error(Anthropic::Errors::InternalServerError, '500'))
      expect { provider.chat(messages: messages) }.to raise_error(Lalabase::Llm::Provider::Error) { |e|
        expect(e).not_to be_a(Lalabase::Llm::Provider::RequestRefusedError)
      }
    end

    # The rescue widened to the SDK's base class; unrecognised subclasses must still
    # reach the caller unchanged rather than be flattened into our vocabulary.
    it 'lets an unmapped SDK error through unchanged' do
      allow(fake_messages).to receive(:create).and_raise(anthropic_error(Anthropic::Errors::ConflictError, '409'))
      expect { provider.chat(messages: messages) }.to raise_error(Anthropic::Errors::ConflictError)
    end
  end

  # -------------------------------------------------------------------------
  # stream_chat
  # -------------------------------------------------------------------------
  describe '#stream_chat' do
    let(:stream_stub) { double('MessageStream') }
    let(:final_msg)   { Struct.new(:content, :usage).new([text_block('Hello world')], usage(input: 8, output: 4)) }

    before do
      allow(fake_messages).to receive(:stream).and_return(stream_stub)
      allow(stream_stub).to receive(:text).and_return(['Hello ', 'world'].each)
      allow(stream_stub).to receive(:accumulated_message).and_return(final_msg)
    end

    it 'requires a block' do
      expect { provider.stream_chat(messages: messages) }.to raise_error(ArgumentError, /requires a block/)
    end

    it 'yields each text delta in order' do
      yielded = []
      provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(['Hello ', 'world'])
    end

    it 'folds a system-only request into a single user turn (parity with #chat)' do
      provider.stream_chat(messages: [{ role: 'system', content: 'Fasse zusammen.' }]) { |_| }
      expect(fake_messages).to have_received(:stream).with(
        satisfy do |params|
          params[:messages] == [{ role: 'user', content: 'Fasse zusammen.' }] && !params.key?(:system_)
        end
      )
    end

    it 'returns accumulated content + final token_usage' do
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:content]).to eq('Hello world')
      expect(result[:token_usage]).to include(input_tokens: 8, output_tokens: 4, total_tokens: 12, estimated: false)
    end

    it 'skips nil and empty deltas' do
      allow(stream_stub).to receive(:text).and_return([nil, '', 'x'].each)
      yielded = []
      provider.stream_chat(messages: messages) { |d| yielded << d }
      expect(yielded).to eq(['x'])
    end

    it 'maps AuthenticationError → AuthError' do
      allow(fake_messages).to receive(:stream).and_raise(anthropic_error(Anthropic::Errors::AuthenticationError, '401'))
      expect { provider.stream_chat(messages: messages) { |_| } }.to raise_error(Lalabase::Llm::Provider::AuthError)
    end

    # The lane the project chat actually fails on: the Runner streams its final turn,
    # so a mapping that held only for #chat would miss every real chat answer.
    it 'maps a refused request (400) → RequestRefusedError' do
      allow(fake_messages).to receive(:stream).and_raise(
        anthropic_error(Anthropic::Errors::BadRequestError, 'credit balance is too low')
      )
      expect { provider.stream_chat(messages: messages) { |_| } }
        .to raise_error(Lalabase::Llm::Provider::RequestRefusedError)
    end

    it 'handles a completely empty stream' do
      allow(stream_stub).to receive(:text).and_return([].each)
      empty_final = Struct.new(:content, :usage).new([text_block('')], usage(input: 0, output: 0))
      allow(stream_stub).to receive(:accumulated_message).and_return(empty_final)
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:content]).to eq('')
    end

    it 'returns the EXACT result hash key set' do
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result.keys.sort).to eq(%i[content model_used token_usage].sort)
    end

    it 'reports estimated:false (Anthropic returns real usage)' do
      result = provider.stream_chat(messages: messages) { |_| }
      expect(result[:token_usage][:estimated]).to be(false)
    end

    it 'propagates exceptions raised inside the on_chunk block (no swallowing)' do
      # In contrast to OpenAi's streaming proc, the Anthropic loop runs in the caller's
      # stack frame — exceptions from on_chunk SHOULD propagate. If someone wraps the
      # `.each` in a `rescue`, this test breaks.
      expect do
        provider.stream_chat(messages: messages) { |_| raise 'caller-bug' }
      end.to raise_error(RuntimeError, 'caller-bug')
    end
  end

  # -------------------------------------------------------------------------
  # Tool-use (M8.3.6)
  # -------------------------------------------------------------------------
  describe '#chat with tools' do
    let(:tools) do
      [{
        name: 'search_code_symbols',
        description: 'semantic search',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      }]
    end

    def tool_use_block(id:, name:, input:)
      Struct.new(:type, :id, :name, :input).new(:tool_use, id, name, input)
    end

    let(:text_only_response) do
      Struct.new(:content, :usage, :stop_reason).new([text_block('plain answer')], usage(input: 10, output: 5), :end_turn)
    end

    let(:tool_call_response) do
      Struct.new(:content, :usage, :stop_reason).new(
        [tool_use_block(id: 'toolu_abc', name: 'search_code_symbols', input: { 'query' => 'auth' })],
        usage(input: 20, output: 8),
        :tool_use
      )
    end

    let(:mixed_response) do
      Struct.new(:content, :usage, :stop_reason).new(
        [text_block('Looking it up...'),
         tool_use_block(id: 'toolu_xyz', name: 'search_code_symbols', input: { 'query' => 'login' })],
        usage(input: 15, output: 12),
        :tool_use
      )
    end

    it 'sends tools in Anthropic flat wire format (no function-wrapper)' do
      allow(fake_messages).to receive(:create).and_return(text_only_response)
      provider.chat(messages: messages, tools: tools)
      expect(fake_messages).to have_received(:create).with(hash_including(
                                                             tools: [{
                                                               name: 'search_code_symbols',
                                                               description: 'semantic search',
                                                               input_schema: tools.first[:input_schema]
                                                             }]
                                                           ))
    end

    it 'omits the tools key when tools is nil' do
      allow(fake_messages).to receive(:create).and_return(text_only_response)
      provider.chat(messages: messages, tools: nil)
      expect(fake_messages).to have_received(:create) do |params|
        expect(params).not_to have_key(:tools)
      end
    end

    it 'returns tool_calls: nil for text-only responses + normalised stop_reason' do
      allow(fake_messages).to receive(:create).and_return(text_only_response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls]).to be_nil
      expect(result[:content]).to eq('plain answer')
      # H2: Anthropic 'end_turn' must be normalised to canonical 'stop'
      expect(result[:stop_reason]).to eq('stop')
    end

    it 'parses a single tool_use block into canonical {id, name, args} form' do
      allow(fake_messages).to receive(:create).and_return(tool_call_response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls]).to eq([
                                          { id: 'toolu_abc', name: 'search_code_symbols',
                                            args: { 'query' => 'auth' } }
                                        ])
      expect(result[:content]).to eq('')
      # H2: Anthropic 'tool_use' must be normalised to canonical 'tool_calls'
      expect(result[:stop_reason]).to eq('tool_calls')
    end

    it 'parses MIXED content (text + tool_use blocks in one response)' do
      allow(fake_messages).to receive(:create).and_return(mixed_response)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:content]).to eq('Looking it up...')
      expect(result[:tool_calls].size).to eq(1)
      expect(result[:tool_calls].first[:id]).to eq('toolu_xyz')
    end

    it 'parses MULTIPLE tool_use blocks (parallel tool use)' do
      multi = Struct.new(:content, :usage, :stop_reason).new(
        [tool_use_block(id: 'toolu_1', name: 'search_code_symbols', input: { 'query' => 'a' }),
         tool_use_block(id: 'toolu_2', name: 'search_code_symbols', input: { 'query' => 'b' })],
        usage, :tool_use
      )
      allow(fake_messages).to receive(:create).and_return(multi)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].map { |tc| tc[:id] }).to eq(%w[toolu_1 toolu_2])
    end

    it 'still raises Error when BOTH content and tool_use are absent' do
      empty = Struct.new(:content, :usage, :stop_reason).new([], usage, :end_turn)
      allow(fake_messages).to receive(:create).and_return(empty)
      expect { provider.chat(messages: messages, tools: tools) }
        .to raise_error(Lalabase::Llm::Provider::Error, /empty/)
    end

    it 'coerces Anthropic input objects (responding to to_h) into plain Hashes' do
      # SDK may return an InputSchema-like object instead of a Hash; defensive
      # to_h normalization is what guarantees the Runner sees a Hash.
      sdk_like = double(to_h: { 'query' => 'auth' })
      block = Struct.new(:type, :id, :name, :input).new(:tool_use, 'toolu_h', 'search_code_symbols', sdk_like)
      resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
      allow(fake_messages).to receive(:create).and_return(resp)
      result = provider.chat(messages: messages, tools: tools)
      expect(result[:tool_calls].first[:args]).to eq({ 'query' => 'auth' })
    end
  end

  describe 'message translation for tool-use (Anthropic-specific)' do
    let(:text_only_response) do
      Struct.new(:content, :usage, :stop_reason).new([text_block('ok')], usage, :end_turn)
    end

    before { allow(fake_messages).to receive(:create).and_return(text_only_response) }

    it 'rewraps assistant-with-tool_calls into mixed content blocks (text + tool_use)' do
      canonical = [
        { role: 'user', content: 'find auth' },
        { role: 'assistant', content: 'I will search',
          tool_calls: [{ id: 'toolu_1', name: 'search_code_symbols', args: { query: 'auth' } }] }
      ]
      provider.chat(messages: canonical, tools: nil)
      expect(fake_messages).to have_received(:create) do |params|
        assistant_turn = params[:messages].find { |m| m[:role] == 'assistant' }
        expect(assistant_turn[:content]).to eq([
                                                 { type: 'text', text: 'I will search' },
                                                 { type: 'tool_use', id: 'toolu_1',
                                                   name: 'search_code_symbols', input: { query: 'auth' } }
                                               ])
      end
    end

    it 'rewraps assistant-with-tool_calls and OMITS the text block when content is nil' do
      canonical = [
        { role: 'user', content: 'find it' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 'toolu_2', name: 'search_code_symbols', args: { query: 'x' } }] }
      ]
      provider.chat(messages: canonical, tools: nil)
      expect(fake_messages).to have_received(:create) do |params|
        assistant_turn = params[:messages].find { |m| m[:role] == 'assistant' }
        expect(assistant_turn[:content].size).to eq(1)
        expect(assistant_turn[:content].first[:type]).to eq('tool_use')
      end
    end

    it 'converts canonical tool-role messages into user-turn with tool_result content block' do
      canonical = [
        { role: 'user', content: 'q' },
        { role: 'assistant', content: nil,
          tool_calls: [{ id: 'toolu_x', name: 'search_code_symbols', args: {} }] },
        { role: 'tool', tool_call_id: 'toolu_x', content: 'no symbols matched' }
      ]
      provider.chat(messages: canonical, tools: nil)
      expect(fake_messages).to have_received(:create) do |params|
        last = params[:messages].last
        expect(last[:role]).to eq('user')
        expect(last[:content]).to eq([{
                                       type: 'tool_result', tool_use_id: 'toolu_x',
                                       content: 'no symbols matched'
                                     }])
      end
    end

    it 'bundles CONSECUTIVE tool-role messages into a single user-turn (Anthropic API requirement)' do
      canonical = [
        { role: 'assistant', content: nil,
          tool_calls: [
            { id: 'toolu_a', name: 'search_code_symbols', args: { query: 'one' } },
            { id: 'toolu_b', name: 'search_code_symbols', args: { query: 'two' } }
          ] },
        { role: 'tool', tool_call_id: 'toolu_a', content: 'result A' },
        { role: 'tool', tool_call_id: 'toolu_b', content: 'result B' }
      ]
      provider.chat(messages: canonical, tools: nil)
      expect(fake_messages).to have_received(:create) do |params|
        # Two messages: 1 assistant (with 2 tool_use blocks), 1 user (with 2 tool_result blocks)
        expect(params[:messages].size).to eq(2)
        user_turn = params[:messages].last
        expect(user_turn[:role]).to eq('user')
        expect(user_turn[:content].size).to eq(2)
        expect(user_turn[:content].map { |b| b[:tool_use_id] }).to eq(%w[toolu_a toolu_b])
      end
    end

    it 'leaves plain user/assistant/system messages alone (string content stays a string)' do
      plain = [
        { role: 'user', content: 'u' },
        { role: 'assistant', content: 'a' }
      ]
      provider.chat(messages: plain, tools: nil)
      expect(fake_messages).to have_received(:create).with(hash_including(messages: plain))
    end
  end

  # -------------------------------------------------------------------------
  # M8.3.6 strict-review fixes (round 1)
  # -------------------------------------------------------------------------
  describe 'strict-review fixes' do
    let(:text_only_response) do
      Struct.new(:content, :usage, :stop_reason).new([text_block('ok')], usage, :end_turn)
    end

    before { allow(fake_messages).to receive(:create).and_return(text_only_response) }

    def tool_use_block(id:, name:, input:, type: :tool_use)
      Struct.new(:type, :id, :name, :input).new(type, id, name, input)
    end

    # H1: orphan + split tool_result bundles must raise Provider::Error
    # before the Anthropic API can reject with an opaque 400.
    describe 'H1 — orphan/split tool_result detection' do
      it 'raises Provider::Error when conversation STARTS with a tool-role (orphan)' do
        canonical = [
          { role: 'tool', tool_call_id: 'orphan', content: 'r' },
          { role: 'user', content: 'q' }
        ]
        expect { provider.chat(messages: canonical) }
          .to raise_error(Lalabase::Llm::Provider::Error, %r{orphan/split tool_result})
      end

      it 'raises Provider::Error on SPLIT bundle (tool → non-tool → tool)' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't1', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't1', content: 'A' },
          { role: 'assistant', content: 'mid text' },
          { role: 'tool', tool_call_id: 't2', content: 'B' }
        ]
        expect { provider.chat(messages: canonical) }
          .to raise_error(Lalabase::Llm::Provider::Error, %r{orphan/split tool_result})
      end

      it 'accepts consecutive tool-roles right after assistant-with-tool_calls (happy path stays green)' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [
              { id: 't1', name: 'x', args: {} },
              { id: 't2', name: 'y', args: {} }
            ] },
          { role: 'tool', tool_call_id: 't1', content: 'A' },
          { role: 'tool', tool_call_id: 't2', content: 'B' }
        ]
        expect { provider.chat(messages: canonical) }.not_to raise_error
      end
    end

    # H2: stop_reason vocabulary normalisation (provider-neutral for Runner).
    describe 'H2 — stop_reason normalisation' do
      [
        [:end_turn,       'stop'],
        [:stop_sequence,  'stop'],
        [:max_tokens,     'length'],
        [:tool_use,       'tool_calls']
      ].each do |anthropic_value, canonical|
        it "maps Anthropic '#{anthropic_value}' → '#{canonical}'" do
          resp = Struct.new(:content, :usage, :stop_reason).new([text_block('x')], usage, anthropic_value)
          allow(fake_messages).to receive(:create).and_return(resp)
          expect(provider.chat(messages: messages)[:stop_reason]).to eq(canonical)
        end
      end

      it 'passes through unknown stop_reason unchanged (forward-compat)' do
        resp = Struct.new(:content, :usage, :stop_reason).new([text_block('x')], usage, :future_reason)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect(provider.chat(messages: messages)[:stop_reason]).to eq('future_reason')
      end

      it 'STOP_REASON_MAP is the locked contract (mutation guard)' do
        expect(described_class::STOP_REASON_MAP).to eq(
          'end_turn' => 'stop',
          'stop_sequence' => 'stop',
          'max_tokens' => 'length',
          'tool_use' => 'tool_calls'
        )
      end
    end

    # H3: Hash-form blocks (String keys) — defensive code was dead-as-tested.
    describe 'H3 — Hash-form blocks (SDK fallback)' do
      it 'parses a Hash-form tool_use block with string keys' do
        hash_block = { 'type' => 'tool_use', 'id' => 'toolu_h', 'name' => 'search',
                       'input' => { 'q' => 'y' } }
        resp = Struct.new(:content, :usage, :stop_reason).new([hash_block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        result = provider.chat(messages: messages)
        expect(result[:tool_calls].first[:id]).to eq('toolu_h')
        expect(result[:tool_calls].first[:name]).to eq('search')
        expect(result[:tool_calls].first[:args]).to eq('q' => 'y')
      end

      it 'parses a Hash-form text block with symbol keys' do
        hash_block = { type: 'text', text: 'hello' }
        resp = Struct.new(:content, :usage, :stop_reason).new([hash_block], usage, :end_turn)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect(provider.chat(messages: messages)[:content]).to eq('hello')
      end
    end

    # H4 — boundary tests
    describe 'H4 — boundary coverage' do
      it 'treats assistant with empty tool_calls Array as plain assistant (M4)' do
        provider.chat(messages: [{ role: 'assistant', content: 'plain', tool_calls: [] }])
        expect(fake_messages).to have_received(:create).with(hash_including(
                                                               messages: [{ role: 'assistant', content: 'plain' }]
                                                             ))
      end

      it 'silently drops unknown block types and continues with text (L2)' do
        unknown = Struct.new(:type).new(:thinking)
        resp = Struct.new(:content, :usage, :stop_reason).new(
          [unknown, text_block('real text')], usage, :end_turn
        )
        allow(fake_messages).to receive(:create).and_return(resp)
        allow(Rails.logger).to receive(:debug)
        expect(provider.chat(messages: messages)[:content]).to eq('real text')
        expect(Rails.logger).to have_received(:debug)
      end

      it 'returns the EXACT result hash key set when tool_calls present (parity with text-only)' do
        resp = Struct.new(:content, :usage, :stop_reason).new(
          [tool_use_block(id: 'x', name: 'y', input: {})], usage, :tool_use
        )
        allow(fake_messages).to receive(:create).and_return(resp)
        result = provider.chat(messages: messages)
        expect(result.keys.sort).to eq(%i[content model_used stop_reason token_usage tool_calls].sort)
      end
    end

    # M1: malformed tool_use blocks (missing id/name) → fail fast.
    describe 'M1 — malformed tool_use rejection' do
      it 'raises Provider::Error when tool_use block has missing id' do
        block = tool_use_block(id: nil, name: 'search', input: {})
        resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect { provider.chat(messages: messages) }
          .to raise_error(Lalabase::Llm::Provider::Error, /malformed tool_use/)
      end

      it 'raises Provider::Error when tool_use block has missing name' do
        block = tool_use_block(id: 'tool_x', name: '', input: {})
        resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect { provider.chat(messages: messages) }
          .to raise_error(Lalabase::Llm::Provider::Error, /malformed tool_use/)
      end
    end

    # M2: input.to_h must return a Hash, else fall back to {}.
    describe 'M2 — defensive Hash coercion of tool_use input' do
      it 'defaults args to {} when input is nil' do
        block = tool_use_block(id: 'x', name: 'y', input: nil)
        resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect(provider.chat(messages: messages)[:tool_calls].first[:args]).to eq({})
      end

      it 'falls back to {} when to_h returns a non-Hash value' do
        sdk_like = double(to_h: 'not a hash')
        block = tool_use_block(id: 'x', name: 'y', input: sdk_like)
        resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect(provider.chat(messages: messages)[:tool_calls].first[:args]).to eq({})
      end

      it 'falls back to {} when to_h raises an error' do
        sdk_like = double
        allow(sdk_like).to receive(:to_h).and_raise(StandardError)
        block = tool_use_block(id: 'x', name: 'y', input: sdk_like)
        resp = Struct.new(:content, :usage, :stop_reason).new([block], usage, :tool_use)
        allow(fake_messages).to receive(:create).and_return(resp)
        expect(provider.chat(messages: messages)[:tool_calls].first[:args]).to eq({})
      end
    end

    # M3: non-String content for assistant turn must coerce to String when
    # wrapping into a text block (instead of producing `{type:'text', text: <Array>}`).
    describe 'M3 — content coercion in text-block wrap' do
      it 'coerces non-String assistant content to String when wrapping' do
        canonical = [{ role: 'assistant', content: %w[re-fed array],
                       tool_calls: [{ id: 't', name: 'x', args: {} }] }]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          text_block = params[:messages].first[:content].find { |b| b[:type] == 'text' }
          expect(text_block[:text]).to be_a(String)
        end
      end

      it 'omits text block when content is empty string (parity with nil)' do
        canonical = [{ role: 'assistant', content: '',
                       tool_calls: [{ id: 't', name: 'x', args: {} }] }]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          assistant = params[:messages].first
          expect(assistant[:content].size).to eq(1)
          expect(assistant[:content].first[:type]).to eq('tool_use')
        end
      end
    end

    # L1: is_error: true propagation for tool results.
    describe 'L1 — is_error propagation' do
      it 'sets is_error: true on the tool_result block when canonical message marks it' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't', content: 'something broke', is_error: true }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          tool_result = params[:messages].last[:content].first
          expect(tool_result[:is_error]).to be true
        end
      end

      it 'omits is_error when canonical message does not set it (default contract)' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't', content: 'ok' }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          tool_result = params[:messages].last[:content].first
          expect(tool_result).not_to have_key(:is_error)
        end
      end
    end

    # L3: tool_call_id from canonical msg should be coerced to String so a
    # Symbol from a JSON-roundtrip or test fixture doesn't reach Anthropic.
    describe 'L3 — tool_call_id String coercion' do
      it 'coerces Symbol tool_call_id to String for the Anthropic wire' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't_sym', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: :t_sym, content: 'ok' }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          expect(params[:messages].last[:content].first[:tool_use_id]).to eq('t_sym')
        end
      end
    end

    # R2-2: tool_call_id nil/empty must fail fast (symmetric with M1 outbound)
    describe 'R2-2 — tool_call_id presence validation' do
      it 'raises Provider::Error when tool message has nil tool_call_id' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: nil, content: 'ok' }
        ]
        expect { provider.chat(messages: canonical) }
          .to raise_error(Lalabase::Llm::Provider::Error, /missing tool_call_id/)
      end

      it 'raises Provider::Error when tool message has empty-string tool_call_id' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: '', content: 'ok' }
        ]
        expect { provider.chat(messages: canonical) }
          .to raise_error(Lalabase::Llm::Provider::Error, /missing tool_call_id/)
      end
    end

    # R2-3: M3 / L4 symmetry — assistant text-block wrap uses the SAME
    # coercion as tool_result content (Hash/Array → JSON, not Ruby inspect).
    describe 'R2-3 — assistant content coercion matches tool-result coercion' do
      it 'JSON-encodes a Hash assistant content (instead of Ruby #inspect)' do
        canonical = [{ role: 'assistant', content: { foo: :bar },
                       tool_calls: [{ id: 't', name: 'x', args: {} }] }]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          text_block = params[:messages].first[:content].find { |b| b[:type] == 'text' }
          expect(text_block[:text]).to eq('{"foo":"bar"}')
          expect(text_block[:text]).not_to include('=>') # no Ruby inspect
        end
      end

      it 'JSON-encodes an Array assistant content (instead of Ruby #inspect)' do
        canonical = [{ role: 'assistant', content: [1, 2, 3],
                       tool_calls: [{ id: 't', name: 'x', args: {} }] }]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          text_block = params[:messages].first[:content].find { |b| b[:type] == 'text' }
          expect(text_block[:text]).to eq('[1,2,3]')
        end
      end
    end

    # R2-4: state-machine happy path for INTERLEAVED tool batches
    # (assistant_tc → tool → assistant_tc → tool). Live-verified to work,
    # but no test pinned the expecting_tool_results re-arming logic.
    describe 'R2-4 — interleaved tool batches' do
      it 'correctly bundles two consecutive assistant-with-tool_calls batches' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't1', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't1', content: 'A' },
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't2', name: 'y', args: {} }] },
          { role: 'tool', tool_call_id: 't2', content: 'B' }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          # 4 wire messages: assistant, user-with-tool_result, assistant, user-with-tool_result
          expect(params[:messages].size).to eq(4)
          expect(params[:messages].map { |m| m[:role] }).to eq(%w[assistant user assistant user])
          expect(params[:messages][1][:content].first[:tool_use_id]).to eq('t1')
          expect(params[:messages][3][:content].first[:tool_use_id]).to eq('t2')
        end
      end
    end

    # L4: non-String tool result content (Hash/Array) JSON-encoded so Claude
    # sees structured data instead of Ruby's #inspect output.
    describe 'L4 — non-String tool result content (JSON-encoded)' do
      it 'JSON-encodes Hash content' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't', content: { rows: 5, ok: true } }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          expect(params[:messages].last[:content].first[:content])
            .to eq('{"rows":5,"ok":true}')
        end
      end

      it 'JSON-encodes Array content' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't', content: [1, 2, 3] }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          expect(params[:messages].last[:content].first[:content]).to eq('[1,2,3]')
        end
      end

      it 'still passes String content through unchanged' do
        canonical = [
          { role: 'assistant', content: nil,
            tool_calls: [{ id: 't', name: 'x', args: {} }] },
          { role: 'tool', tool_call_id: 't', content: 'plain string' }
        ]
        provider.chat(messages: canonical)
        expect(fake_messages).to have_received(:create) do |params|
          expect(params[:messages].last[:content].first[:content]).to eq('plain string')
        end
      end
    end
  end

  # -------------------------------------------------------------------------
  # embed
  # -------------------------------------------------------------------------
  describe '#embed' do
    it 'raises NotSupportedError (Anthropic has no embedding model)' do
      expect { provider.embed(text: 'x') }.to raise_error(Lalabase::Llm::Provider::NotSupportedError, /anthropic/)
    end
  end
end
