# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::VisionGenerator do
  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }
  let(:scan) do
    {
      readme: { name: 'README.md', content: '# Lalabase\nA ticketing platform.' },
      manifests: { 'Gemfile' => "source 'https://rubygems.org'" },
      claude_md: { name: 'CLAUDE.md', content: '# Rules' },
      top_level: ['app/', 'config/', 'Gemfile'],
      language_hint: 'ruby'
    }
  end

  def chat_result(content: 'A short project description.')
    {
      content: content,
      model_used: 'gpt-4o-mini',
      token_usage: { input_tokens: 100, output_tokens: 50, total_tokens: 150 }
    }
  end

  describe '#call (happy path)' do
    before { allow(provider).to receive(:chat).and_return(chat_result) }

    it 'returns content, language, model_used, token_usage' do
      result = described_class.new(provider: provider, scan: scan).call
      expect(result).to include(content: 'A short project description.',
                                language: 'en',
                                model_used: 'gpt-4o-mini')
      expect(result[:token_usage]).to include(total_tokens: 150)
    end

    it 'strips whitespace from content' do
      allow(provider).to receive(:chat).and_return(chat_result(content: "  has space  \n"))
      expect(described_class.new(provider: provider, scan: scan).call[:content]).to eq('has space')
    end

    it 'asks the provider with system + user roles' do
      described_class.new(provider: provider, scan: scan).call
      expect(provider).to have_received(:chat).with(
        hash_including(messages: array_including(
          a_hash_including(role: 'system'),
          a_hash_including(role: 'user')
        ))
      )
    end

    it 'forwards MAX_TOKENS and TEMPERATURE constants to the provider (locked contract)' do
      described_class.new(provider: provider, scan: scan).call
      expect(provider).to have_received(:chat).with(hash_including(
                                                      max_tokens: described_class::MAX_TOKENS,
                                                      temperature: described_class::TEMPERATURE
                                                    ))
    end
  end

  describe 'language whitelist' do
    before { allow(provider).to receive(:chat).and_return(chat_result) }

    described_class::SUPPORTED_LANGUAGES.each do |lang|
      it "accepts #{lang.inspect}" do
        expect(described_class.new(provider: provider, scan: scan, language: lang).call[:language]).to eq(lang)
      end
    end

    it 'falls back to DEFAULT_LANGUAGE for unknown language values' do
      result = described_class.new(provider: provider, scan: scan, language: 'fr').call
      expect(result[:language]).to eq(described_class::DEFAULT_LANGUAGE)
    end

    it 'falls back to DEFAULT_LANGUAGE for nil' do
      result = described_class.new(provider: provider, scan: scan, language: nil).call
      expect(result[:language]).to eq(described_class::DEFAULT_LANGUAGE)
    end
  end

  describe 'prompt content (catches silent prompt regressions)' do
    before { allow(provider).to receive(:chat).and_return(chat_result) }

    it 'includes the README content in the user prompt' do
      described_class.new(provider: provider, scan: scan).call
      user_msg = captured_user_message
      expect(user_msg).to include('A ticketing platform')
    end

    it 'includes the CLAUDE.md content when present' do
      described_class.new(provider: provider, scan: scan).call
      expect(captured_user_message).to include('# Rules')
    end

    it 'includes the top-level directory listing' do
      described_class.new(provider: provider, scan: scan).call
      expect(captured_user_message).to include('app/').and include('config/')
    end

    it 'includes the language hint when present' do
      described_class.new(provider: provider, scan: scan).call
      expect(captured_user_message).to include('ruby')
    end

    it 'iterates over MULTIPLE manifests in the prompt (catches removed loop)' do
      multi = scan.merge(manifests: { 'Gemfile' => 'g-content', 'package.json' => '{"p":"json"}' })
      described_class.new(provider: provider, scan: multi).call
      msg = captured_user_message
      expect(msg).to include('Gemfile').and include('g-content')
      expect(msg).to include('package.json').and include('json')
    end

    it 'falls back to a benign placeholder when scan is empty' do
      empty_scan = { readme: nil, manifests: {}, claude_md: nil, top_level: [], language_hint: nil }
      described_class.new(provider: provider, scan: empty_scan).call
      expect(captured_user_message).to include('No metadata available')
    end

    it 'switches the system prompt to German when language=de' do
      described_class.new(provider: provider, scan: scan, language: 'de').call
      sys_msg = captured_system_message
      expect(sys_msg).to include('Du bist').and include('deutsch')
    end

    it 'uses an English system prompt when language=en' do
      described_class.new(provider: provider, scan: scan, language: 'en').call
      expect(captured_system_message).to include('software analyst').and include('flowing prose')
    end
  end

  describe 'constants locked' do
    it { expect(described_class::MAX_TOKENS).to eq(800) }
    it { expect(described_class::TEMPERATURE).to eq(0.3) }
    it { expect(described_class::DEFAULT_LANGUAGE).to eq('en') }
    it { expect(described_class::SUPPORTED_LANGUAGES).to contain_exactly('de', 'en') }
  end

  describe 'defensive handling of provider response' do
    it 'returns empty content (no crash) when provider returns nil content' do
      allow(provider).to receive(:chat).and_return(
        content: nil, model_used: 'gpt', token_usage: {}
      )
      expect(described_class.new(provider: provider, scan: scan).call[:content]).to eq('')
    end

    it 'propagates provider errors (caller — the job — must handle, not the generator)' do
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError, '401')
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(Lalabase::Llm::Provider::AuthError)
    end
  end

  def captured_user_message
    provider.instance_variable_get(:@invocations) # not used; instead reflect last call args
    begin
      RSpec::Mocks.space.proxy_for(provider).messages_arg_list
    rescue StandardError
      nil
    end
    # Fallback to RSpec's `have_received` approach
    msgs = nil
    expect(provider).to have_received(:chat) { |kwargs| msgs = kwargs[:messages] }
    msgs.find { |m| m[:role] == 'user' }[:content]
  end

  def captured_system_message
    msgs = nil
    expect(provider).to have_received(:chat) { |kwargs| msgs = kwargs[:messages] }
    msgs.find { |m| m[:role] == 'system' }[:content]
  end
end
