# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomerDescriptionGenerator, type: :service do
  let!(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let!(:user) do
    ActsAsTenant.with_tenant(organisation) do
      create(:user, organisation: organisation)
    end
  end
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project)
    end
  end
  let!(:time_session) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session,
             organisation: organisation,
             project: project,
             ticket: ticket,
             creator: user,
             description: 'Test description',
             duration: 60) # 1 hour in minutes
    end
  end

  # Set tenant for all tests
  around do |example|
    ActsAsTenant.with_tenant(organisation) do
      example.run
    end
  end

  describe '#clean_and_truncate' do
    subject(:generator) { described_class.new(time_session) }

    context 'when text is within flexible limit' do
      it 'returns the full text' do
        text = 'Dies ist ein kurzer Satz.'
        result = generator.send(:clean_and_truncate, text)
        expect(result).to eq(text)
      end
    end

    context 'when text exceeds limit but has sentence endings' do
      it 'truncates at last complete sentence' do
        # Create text that exceeds MAX_LENGTH (250) but has sentence boundaries
        text = 'Dies ist der erste Satz. ' * 10 + 'Dies ist der letzte sehr lange Satz der abgeschnitten werden sollte.'
        result = generator.send(:clean_and_truncate, text)

        # Should end with a period (complete sentence)
        expect(result).to end_with('.')
        # Should not contain the last incomplete part
        expect(result).not_to include('abgeschnitten werden sollte')
        # Should be within flexible limit (250 * 1.2 = 300)
        expect(result.length).to be <= 300
      end

      it 'handles multiple sentence endings (., !, ?)' do
        # Create text with mixed endings that stays within flexible limit
        text = 'Erster Satz! Zweiter Satz? Dritter Satz.'
        result = generator.send(:clean_and_truncate, text)

        expect(result).to match(/[.!?]\z/)
        expect(result).to eq(text)
      end
    end

    context 'when text has no sentence endings within limit' do
      it 'falls back to hard truncate with warning' do
        # Single long sentence without periods
        text = 'Dies ist ein sehr sehr sehr langer Satz ohne Punkt oder andere Satzzeichen ' * 10

        expect(Rails.logger).to receive(:warn).with(/Could not find sentence boundary/)

        result = generator.send(:clean_and_truncate, text)
        expect(result).to end_with('...')
        expect(result.length).to be <= CustomerDescriptionGenerator::MAX_LENGTH
      end
    end

    context 'when text is nil or blank' do
      it 'returns nil for nil' do
        result = generator.send(:clean_and_truncate, nil)
        expect(result).to be_nil
      end

      it 'returns nil for blank string' do
        result = generator.send(:clean_and_truncate, '   ')
        expect(result).to be_nil
      end
    end

    context 'when text has leading/trailing quotes' do
      it 'removes surrounding quotes' do
        text = '"Dies ist ein Satz."'
        result = generator.send(:clean_and_truncate, text)
        expect(result).to eq('Dies ist ein Satz.')
      end

      it 'removes single quotes' do
        text = "'Dies ist ein Satz.'"
        result = generator.send(:clean_and_truncate, text)
        expect(result).to eq('Dies ist ein Satz.')
      end
    end

    context 'for long sessions (> 2 hours)' do
      let!(:long_time_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation,
                 project: project,
                 ticket: ticket,
                 creator: user,
                 description: 'Test description',
                 duration: 150) # 2.5 hours = 150 minutes
        end
      end

      subject(:long_generator) { described_class.new(long_time_session) }

      it 'allows longer text (MIN_LENGTH_FOR_LONG_SESSIONS)' do
        # Create text around 500 characters
        text = 'Dies ist ein Satz für eine lange Session. ' * 12
        result = long_generator.send(:clean_and_truncate, text)

        # Should allow up to MIN_LENGTH_FOR_LONG_SESSIONS * 1.2 = 600
        expect(result.length).to be <= 600
        expect(result).to end_with('.')
      end
    end
  end

  # R3: the AI path routes through Lalabase::Llm::Factory.for_feature — by FEATURE
  # KEY, not by a provider literal. gpt-5-nano is a reasoning model: the provider maps
  # max_tokens → max_completion_tokens and drops temperature; reasoning_effort rides
  # along in provider_options. That dialect is why the registry row is pinned, and the
  # pin is now the only thing this service knows about the provider.
  describe '#generate (AI path, R3)' do
    # The generator queries tenanted posts (build_context) before ever calling the
    # model, so it needs a tenant set — as it does in production. The around block's
    # tenant is cleared by the suite's global reset before each example.
    before { ActsAsTenant.current_tenant = organisation }

    let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai') }
    let(:chat_result) do
      { content: 'Wir haben den Login-Fehler behoben.', model_used: 'gpt-5-nano',
        token_usage: { input_tokens: 30, output_tokens: 12, total_tokens: 42 } }
    end

    it 'returns nil without touching the seam when AI is disabled (GDPR gate)' do
      organisation.update!(ai_enabled: false)
      expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
      expect(described_class.new(time_session).generate).to be_nil
    end

    it 'generates a description via the provider and records one AiUsage row' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)

      result = nil
      expect { result = described_class.new(time_session).generate }.to change(AiUsage, :count).by(1)
      expect(result).to include('Login-Fehler behoben')
    end

    it 'passes gpt-5-nano with reasoning_effort through provider_options' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)

      described_class.new(time_session).generate

      expect(provider).to have_received(:chat)
        .with(hash_including(model: 'gpt-5-nano', provider_options: { reasoning_effort: 'minimal' }))
    end

    # R3, the routing half: the service names a FEATURE, and the registry row behind
    # that name carries the pin. Reverting this line to
    # Factory.build(provider_name: …) would restore a second, independent statement
    # of the pin — the exact drift the registry exists to make impossible — and it
    # would be invisible to every other example here, because both spellings reach
    # OpenAI. Only the call itself tells them apart.
    it 'routes by feature key, never by a provider literal' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_return(provider)
      allow(Lalabase::Llm::Factory).to receive(:build).and_call_original
      allow(provider).to receive(:chat).and_return(chat_result)

      described_class.new(time_session).generate

      expect(Lalabase::Llm::Factory).to have_received(:for_feature).with(:customer_description, organisation)
      expect(Lalabase::Llm::Factory).not_to have_received(:build)
    end

    it 'still reaches OpenAI for an org routing elsewhere (Fix C regression, now via the pin row)' do
      # gpt-5-nano + reasoning_effort are OpenAI-specific; a route following the org's
      # choice would send them to Anthropic. The registry is unstubbed here — this is
      # the whole chain, from the service's feature key to the class it gets back.
      organisation.update!(ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'a' * 95}")
      create(:ai_credential, :active, provider: 'openai')
      built = nil
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_wrap_original do |original, *args|
        # Stubbing #chat on the REAL instance rather than the class keeps a wrong
        # route from silently reaching the network instead of failing the example.
        built = original.call(*args)
        allow(built).to receive(:chat).and_return(chat_result)
        built
      end

      described_class.new(time_session).generate

      expect(built).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'returns nil (description stays empty) when the provider auth fails' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError, '401')
      expect(described_class.new(time_session).generate).to be_nil
    end
  end

  describe '#truncate_at_sentence_end' do
    subject(:generator) { described_class.new(time_session) }

    it 'finds last sentence ending within limit' do
      text = 'Erster Satz. Zweiter Satz. Dritter Satz.'
      result = generator.send(:truncate_at_sentence_end, text, 27)

      # Should include first two sentences (up to position 26)
      expect(result).to eq('Erster Satz. Zweiter Satz.')
    end

    it 'returns nil when no sentence ending found' do
      text = 'Ein langer Satz ohne Punkt'
      result = generator.send(:truncate_at_sentence_end, text, 15)

      expect(result).to be_nil
    end

    it 'returns original text if within limit' do
      text = 'Kurzer Satz.'
      result = generator.send(:truncate_at_sentence_end, text, 100)

      expect(result).to eq(text)
    end

    it 'handles exclamation marks' do
      text = 'Wichtig! Noch wichtiger! Zu lang.'
      result = generator.send(:truncate_at_sentence_end, text, 25)

      # Should include first two sentences (up to position 24)
      expect(result).to eq('Wichtig! Noch wichtiger!')
    end

    it 'handles question marks' do
      text = 'Frage eins? Frage zwei? Frage drei?'
      result = generator.send(:truncate_at_sentence_end, text, 24)

      # Should include first two sentences
      expect(result).to eq('Frage eins? Frage zwei?')
    end

    it 'avoids very short truncations (abbreviation protection)' do
      text = 'z.B. dies ist ein Beispiel. Hier ist ein weiterer Satz.'
      # If it would truncate at "z.B." (position 3), it should skip to next sentence
      result = generator.send(:truncate_at_sentence_end, text, 30)

      # Should skip the abbreviation and go to the next real sentence
      expect(result.length).to be > 10
    end
  end
end
