# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::CapabilityGenerator do
  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }
  let(:scan) do
    { readme: { name: 'README.md', content: '# X' },
      manifests: { 'Gemfile' => 'g' },
      claude_md: nil,
      top_level: ['app/', 'lib/'],
      language_hint: 'ruby' }
  end

  def chat_result(content)
    { content: content, model_used: 'gpt-4o-mini',
      token_usage: { input_tokens: 50, output_tokens: 200, total_tokens: 250 } }
  end

  def valid_json
    { capabilities: [
      { name: 'Notification System',
        description: 'Sends in-app and email notifications based on events.' },
      { name: 'Multi-Tenancy',
        description: 'Scopes every record to the current organisation.' }
    ] }.to_json
  end

  describe 'error hierarchy' do
    it 'ParseError descends from StandardError' do
      expect(described_class::ParseError.ancestors).to include(StandardError)
    end
  end

  describe '#call (happy path)' do
    before { allow(provider).to receive(:chat).and_return(chat_result(valid_json)) }

    it 'returns parsed capabilities, language, model_used, token_usage' do
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities].size).to eq(2)
      expect(result[:capabilities].first).to include(name: 'Notification System',
                                                     description: include('notifications'),
                                                     key_modules: [])
      expect(result[:language]).to eq('en')
      expect(result[:model_used]).to eq('gpt-4o-mini')
    end

    it 'asks the provider with the locked MAX_TOKENS / TEMPERATURE' do
      described_class.new(provider: provider, scan: scan).call
      expect(provider).to have_received(:chat).with(hash_including(
                                                      max_tokens: described_class::MAX_TOKENS,
                                                      temperature: described_class::TEMPERATURE
                                                    ))
    end
  end

  describe 'JSON parsing robustness (LLM output is unreliable)' do
    it 'strips ```json fences from the LLM response' do
      fenced = "```json\n#{valid_json}\n```"
      allow(provider).to receive(:chat).and_return(chat_result(fenced))
      expect(described_class.new(provider: provider, scan: scan).call[:capabilities].size).to eq(2)
    end

    it 'strips ``` (no language tag) fences' do
      fenced = "```\n#{valid_json}\n```"
      allow(provider).to receive(:chat).and_return(chat_result(fenced))
      expect(described_class.new(provider: provider, scan: scan).call[:capabilities].size).to eq(2)
    end

    it 'accepts a bare JSON array (not wrapped in {capabilities: ...})' do
      bare_array = [
        { 'name' => 'Cap A', 'description' => 'descA' },
        { 'name' => 'Cap B', 'description' => 'descB' }
      ].to_json
      allow(provider).to receive(:chat).and_return(chat_result(bare_array))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities].size).to eq(2)
    end

    it 'raises ParseError on invalid JSON' do
      allow(provider).to receive(:chat).and_return(chat_result('not json at all'))
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(described_class::ParseError, /invalid JSON/)
    end

    it 'raises ParseError when JSON is valid but shape is unexpected (string)' do
      allow(provider).to receive(:chat).and_return(chat_result('"a string"'))
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(described_class::ParseError, /array/)
    end

    it 'silently drops capability entries that lack name or description' do
      mixed = { 'capabilities' => [
        { 'name' => 'Real', 'description' => 'good' },
        { 'name' => '',     'description' => 'no name' },
        { 'name' => 'X',    'description' => '' },
        { 'description' => 'no name key' }
      ] }.to_json
      allow(provider).to receive(:chat).and_return(chat_result(mixed))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities].map { |c| c[:name] }).to eq(['Real'])
    end

    it 'caps the result at MAX_CAPABILITIES' do
      overshoot = { 'capabilities' => (1..50).map { |i| { 'name' => "C#{i}", 'description' => "d#{i}" } } }.to_json
      allow(provider).to receive(:chat).and_return(chat_result(overshoot))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities].size).to eq(described_class::MAX_CAPABILITIES)
    end

    it 'strips whitespace from name and description' do
      payload = { 'capabilities' => [{ 'name' => '  Foo  ', 'description' => "\n bar \n" }] }.to_json
      allow(provider).to receive(:chat).and_return(chat_result(payload))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities].first).to include(name: 'Foo', description: 'bar')
    end

    it 'initialises key_modules to an empty array (gets filled in M6)' do
      allow(provider).to receive(:chat).and_return(chat_result(valid_json))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities]).to all(include(key_modules: []))
    end
  end

  describe 'language whitelist' do
    before { allow(provider).to receive(:chat).and_return(chat_result(valid_json)) }

    described_class::SUPPORTED_LANGUAGES.each do |lang|
      it "accepts #{lang.inspect}" do
        expect(
          described_class.new(provider: provider, scan: scan, language: lang).call[:language]
        ).to eq(lang)
      end
    end

    it 'falls back to DEFAULT_LANGUAGE on unsupported value' do
      result = described_class.new(provider: provider, scan: scan, language: 'pt').call
      expect(result[:language]).to eq(described_class::DEFAULT_LANGUAGE)
    end
  end

  describe 'constants locked' do
    it { expect(described_class::MAX_CAPABILITIES).to eq(25) }
    it { expect(described_class::MIN_CAPABILITIES).to eq(3) }
    it { expect(described_class::MAX_TOKENS).to eq(1500) }
    it { expect(described_class::TEMPERATURE).to eq(0.2) }
    it { expect(described_class::SUPPORTED_LANGUAGES).to contain_exactly('de', 'en') }
    it { expect(described_class::MAX_NAME_LENGTH).to eq(100) }
    it { expect(described_class::MAX_DESCRIPTION_LENGTH).to eq(2_000) }
  end

  describe 'length caps on LLM output (DoS / cost protection)' do
    it 'truncates description to MAX_DESCRIPTION_LENGTH characters' do
      huge = 'x' * 10_000
      payload = { 'capabilities' => [{ 'name' => 'Long', 'description' => huge }] }.to_json
      allow(provider).to receive(:chat).and_return(chat_result(payload))
      desc = described_class.new(provider: provider, scan: scan).call[:capabilities].first[:description]
      expect(desc.length).to eq(described_class::MAX_DESCRIPTION_LENGTH)
    end

    it 'truncates name to MAX_NAME_LENGTH characters' do
      long = 'X' * 500
      payload = { 'capabilities' => [{ 'name' => long, 'description' => 'd' }] }.to_json
      allow(provider).to receive(:chat).and_return(chat_result(payload))
      name = described_class.new(provider: provider, scan: scan).call[:capabilities].first[:name]
      expect(name.length).to eq(described_class::MAX_NAME_LENGTH)
    end
  end

  describe 'defensive handling of provider response' do
    it 'raises ParseError when provider returns empty string content' do
      allow(provider).to receive(:chat).and_return(chat_result(''))
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(described_class::ParseError)
    end

    it 'raises ParseError when JSON has "capabilities": null' do
      allow(provider).to receive(:chat).and_return(chat_result({ 'capabilities' => nil }.to_json))
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(described_class::ParseError, /array/)
    end

    it 'raises ParseError when "capabilities" is a string, not an array' do
      allow(provider).to receive(:chat)
        .and_return(chat_result({ 'capabilities' => 'we have many capabilities' }.to_json))
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(described_class::ParseError, /array/)
    end

    it 'handles code-fence with leading prose AND trailing whitespace (real LLM behaviour)' do
      fenced = "Sure, here you go:\n\n```json\n#{valid_json}\n```\n\n  "
      allow(provider).to receive(:chat).and_return(chat_result(fenced))
      expect(described_class.new(provider: provider, scan: scan).call[:capabilities].size).to eq(2)
    end

    it 'returns empty capabilities array when JSON has "capabilities": []' do
      allow(provider).to receive(:chat).and_return(chat_result({ 'capabilities' => [] }.to_json))
      result = described_class.new(provider: provider, scan: scan).call
      expect(result[:capabilities]).to eq([])
    end

    it 'propagates provider errors (job — not the generator — must handle)' do
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::RateLimitError, '429')
      expect do
        described_class.new(provider: provider, scan: scan).call
      end.to raise_error(Lalabase::Llm::Provider::RateLimitError)
    end
  end
end
