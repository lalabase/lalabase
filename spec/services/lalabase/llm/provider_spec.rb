# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Llm::Provider do
  subject(:provider) { described_class.new(api_key: 'k') }

  describe Lalabase::Llm::Provider::TruncatedError do
    it 'is a Provider::Error, so every caller that rescues Error behaves as before' do
      expect(described_class.ancestors).to include(Lalabase::Llm::Provider::Error)
    end

    it 'always carries a Hash as result, also when raised without one or with nil' do
      expect(described_class.new('cut').result).to eq({})
      expect(described_class.new('cut', result: nil).result).to eq({})
    end
  end

  describe '#chat / #stream_chat / #embed' do
    it 'raises NotImplementedError on chat' do
      expect { provider.chat(messages: []) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError on stream_chat' do
      expect { provider.stream_chat(messages: []) { |_| } }.to raise_error(NotImplementedError)
    end

    it 'raises NotSupportedError on embed by default' do
      expect { provider.embed(text: 'x') }.to raise_error(described_class::NotSupportedError)
    end

    it 'raises NotImplementedError on default_chat_model' do
      expect { provider.default_chat_model }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError on connectivity_check (concrete providers must implement it)' do
      expect { provider.connectivity_check }.to raise_error(NotImplementedError)
    end
  end

  # The per-text fallback (KI-Pakete P4a+). NOT a placeholder: the Vertex :predict
  # endpoint accepts one instance per call, so GoogleVertexProvider stays on this
  # path deliberately — and it is the path that has to keep the token sum honest,
  # because the bill hangs on the token count, not on how many HTTP calls carried it.
  describe '#embed_batch_with_usage (base fallback)' do
    # A minimal concrete provider: only #embed_with_usage, exactly what a
    # single-instance endpoint implements.
    let(:single_call_provider) do
      Class.new(described_class) do
        def embed_with_usage(text:, model: nil) # rubocop:disable Lint/UnusedMethodArgument
          { embedding: [text.length.to_f], total_tokens: text.length }
        end
      end.new(api_key: 'k')
    end

    it 'sums the tokens of every single-text call and keeps the vectors in order' do
      result = single_call_provider.embed_batch_with_usage(texts: %w[ab abcd])

      expect(result[:embeddings]).to eq([[2.0], [4.0]])
      # 2 + 4 — the assertion that separates summing from taking the last (which
      # would be 4) or the first (2). Both would look plausible on a single input.
      expect(result[:total_tokens]).to eq(6)
    end

    it 'lets #embed_batch delegate here, so the metered path is the only path' do
      expect(single_call_provider.embed_batch(texts: %w[ab abcd])).to eq([[2.0], [4.0]])
    end

    it 'raises NotSupportedError by default, like #embed' do
      expect { provider.embed_batch_with_usage(texts: ['x']) }
        .to raise_error(described_class::NotSupportedError)
    end
  end

  describe '.provider_name' do
    it 'returns the underscored class name without "Provider" suffix' do
      stub_const('Lalabase::Llm::FooBarProvider', Class.new(described_class))
      expect(Lalabase::Llm::FooBarProvider.provider_name).to eq('foo_bar')
    end
  end

  describe '.supports_embeddings?' do
    # Capability declaration (S1): drives the purpose validation in
    # AiCredentialProviderRules. The base class must default to FALSE so a new
    # provider cannot silently claim an embedding capability it does not have.
    it 'defaults to false on the base class' do
      expect(described_class.supports_embeddings?).to be(false)
    end

    it 'is inherited as false by a plain subclass' do
      stub_const('Lalabase::Llm::ChatOnlyProvider', Class.new(described_class))
      expect(Lalabase::Llm::ChatOnlyProvider.supports_embeddings?).to be(false)
    end
  end

  describe 'DEFAULT_EMBEDDING_DIMS (v2 §3.2 — renamed from EXPECTED_EMBEDDING_DIMS)' do
    # The constant was renamed from EXPECTED_EMBEDDING_DIMS to signal that 1536 is
    # now only the DEFAULT, not a hard lane. Pin both the value and the removal of
    # the old name so a stray reference to the old constant fails loudly.
    it 'is 1536' do
      expect(described_class::DEFAULT_EMBEDDING_DIMS).to eq(1536)
    end

    it 'no longer defines the old EXPECTED_EMBEDDING_DIMS name' do
      expect(described_class.const_defined?(:EXPECTED_EMBEDDING_DIMS)).to be(false)
    end
  end

  describe '#guard_dimensions (configurable dimension guard, v2 §3.2)' do
    # guard_dimensions is protected; call via send. The expected dimension is the
    # CONFIGURED embedding_dims when set, else DEFAULT_EMBEDDING_DIMS — so nil
    # behaves exactly like the old hard 1536 lane, and a configured non-1536 space
    # accepts its own size and rejects others (the space is the (provider, model,
    # dims) triple, not just any 1536 vector).
    def guarded(vector, **kwargs)
      described_class.new(api_key: 'k', **kwargs).send(:guard_dimensions, vector)
    end

    context 'with no configured dim (nil → DEFAULT 1536, unchanged v1 behaviour)' do
      it 'accepts exactly 1536' do
        expect { guarded(Array.new(1536, 0.0)) }.not_to raise_error
      end

      [1535, 1537].each do |dims|
        it "rejects #{dims} (n-1/n+1 boundary against the default)" do
          expect { guarded(Array.new(dims, 0.0)) }
            .to raise_error(described_class::DimensionMismatchError, /#{dims} dimensions, expected 1536/)
        end
      end

      it 'drops the misleading "1536-dim models only" wording (v2 rewording)' do
        expect { guarded(Array.new(1000, 0.0)) }
          .to raise_error(described_class::DimensionMismatchError) do |e|
          expect(e.message).not_to include('1536-dim models only')
        end
      end
    end

    context 'with a configured dim (the space is the triple)' do
      it 'accepts a vector matching the configured 1024' do
        expect { guarded(Array.new(1024, 0.0), embedding_dims: 1024) }.not_to raise_error
      end

      it 'rejects the default 1536 when 1024 is configured' do
        expect { guarded(Array.new(1536, 0.0), embedding_dims: 1024) }
          .to raise_error(described_class::DimensionMismatchError, /1536 dimensions, expected 1024/)
      end

      it 'enforces the 767/768/769 boundary for a 768-configured space' do
        expect { guarded(Array.new(768, 0.0), embedding_dims: 768) }.not_to raise_error
        expect { guarded(Array.new(767, 0.0), embedding_dims: 768) }
          .to raise_error(described_class::DimensionMismatchError)
        expect { guarded(Array.new(769, 0.0), embedding_dims: 768) }
          .to raise_error(described_class::DimensionMismatchError)
      end
    end
  end

  describe 'error hierarchy' do
    # Iterate over the full set so removing any one class from the file fails fast.
    {
      AuthError: described_class::AuthError,
      RateLimitError: described_class::RateLimitError,
      NotSupportedError: described_class::NotSupportedError
    }.each_pair do |name, klass|
      it "#{name} descends from Provider::Error (so a single rescue catches it)" do
        expect(klass.ancestors).to include(described_class::Error)
      end
    end

    it 'Error descends from StandardError (so generic rescue catches the family)' do
      expect(described_class::Error.ancestors).to include(StandardError)
    end

    it 'AuthError and RateLimitError are not aliases of each other (rescue precedence matters)' do
      expect(described_class::AuthError).not_to equal(described_class::RateLimitError)
    end
  end

  describe '#provider_name (instance delegation)' do
    # Catches the mutation: someone removes `delegate :provider_name, to: :class`
    # and the instance method silently returns nil or raises.
    it 'delegates to the class method' do
      subclass = stub_const('Lalabase::Llm::FooBarProvider', Class.new(described_class))
      expect(subclass.new(api_key: 'k').provider_name).to eq('foo_bar')
    end
  end

  describe '#effective_provider_name (attribution / provenance name, S2)' do
    # provider_name is the ROUTING key; effective_provider_name is the display name
    # attribution/provenance/Art. 13 must carry — distinct concerns that must not merge.
    it 'returns the configured display name when the Factory injected one from the credential' do
      subclass = stub_const('Lalabase::Llm::FooBarProvider', Class.new(described_class))
      provider = subclass.new(api_key: 'k', provider_name: 'Mistral EU')
      expect(provider.effective_provider_name).to eq('Mistral EU')
      expect(provider.provider_name).to eq('foo_bar') # routing key unchanged
    end

    it 'falls back to the routing key when nothing is configured (honest, not misleading)' do
      subclass = stub_const('Lalabase::Llm::FooBarProvider', Class.new(described_class))
      expect(subclass.new(api_key: 'k').effective_provider_name).to eq('foo_bar')
    end
  end

  describe '#split_system (protected helper)' do
    # We test via send because the helper is used by AnthropicProvider and is the
    # single point where provider-neutral messages get adapted to Claude's API shape.
    # Any mutation here breaks Anthropic chat completely.
    let(:helper) { described_class.new(api_key: 'k') }

    it 'extracts a single system message' do
      sys, conv = helper.send(:split_system, [
                                { role: 'system', content: 'You are helpful.' },
                                { role: 'user',   content: 'Hi' }
                              ])
      expect(sys).to eq('You are helpful.')
      expect(conv).to eq([{ role: 'user', content: 'Hi' }])
    end

    it 'concatenates multiple system messages with double newline' do
      sys, conv = helper.send(:split_system, [
                                { role: 'system', content: 'Part A' },
                                { role: 'system', content: 'Part B' },
                                { role: 'user',   content: 'Hi' }
                              ])
      expect(sys).to eq("Part A\n\nPart B")
      expect(conv).to eq([{ role: 'user', content: 'Hi' }])
    end

    it 'returns nil for empty system when none present' do
      sys, conv = helper.send(:split_system, [{ role: 'user', content: 'Hi' }])
      expect(sys).to be_nil
      expect(conv).to eq([{ role: 'user', content: 'Hi' }])
    end

    it 'treats role as string-comparable (symbol or string)' do
      sys, = helper.send(:split_system, [{ role: :system, content: 'X' },
                                         { role: 'user', content: 'Y' }])
      expect(sys).to eq('X')
    end

    # Turn-based APIs (Anthropic messages, Gemini contents) reject a request
    # without a single conversation turn. A system-only caller means "this is
    # the whole prompt" — the helper carries that intent as the one user turn
    # instead of producing an empty conversation (production 400, 2026-08-02).
    it 'folds a system-only input into a single user turn (no system prompt left)' do
      sys, conv = helper.send(:split_system, [{ role: 'system', content: 'Do X.' }])
      expect(sys).to be_nil
      expect(conv).to eq([{ role: 'user', content: 'Do X.' }])
    end

    it 'joins multiple system-only messages before folding' do
      sys, conv = helper.send(:split_system, [{ role: 'system', content: 'A' },
                                              { role: 'system', content: 'B' }])
      expect(sys).to be_nil
      expect(conv).to eq([{ role: 'user', content: "A\n\nB" }])
    end

    it 'leaves a fully empty input untouched (no invented turn)' do
      # Deliberate boundary: with no content there is no intent to carry — an
      # empty list stays empty. Rejecting it loudly is the normaliser seam's
      # job (PR 2), not this helper's.
      sys, conv = helper.send(:split_system, [])
      expect(sys).to be_nil
      expect(conv).to eq([])
    end
  end
end
