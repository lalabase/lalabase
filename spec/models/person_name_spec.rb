# frozen_string_literal: true

require 'rails_helper'

# One normalizer for meeting participants and the people directory. The same
# fixture pins the JS mirror (spec/javascript/meetings/name_normalizer.test.js),
# so all three read one contract.
RSpec.describe PersonName do
  cases = JSON.parse(File.read(Rails.root.join('spec/fixtures/name_normalization_cases.json')))['cases']

  cases.each do |c|
    it "normalizes #{c['input'].inspect} -> #{c['expected'].inspect} (#{c['why']})" do
      expect(described_class.normalize(c['input'])).to eq(c['expected'])
    end
  end

  it 'treats nil as empty' do
    expect(described_class.normalize(nil)).to eq('')
  end

  describe '.without_note' do
    it 'drops every note in round brackets and the space around it' do
      expect(described_class.without_note('J. Weber (Hoster) (extern)')).to eq('J. Weber')
      expect(described_class.without_note('Anna (IT) Berg')).to eq('Anna Berg')
    end

    it 'keeps a name without a note as it is' do
      expect(described_class.without_note('Jonas Weber')).to eq('Jonas Weber')
    end

    it 'is empty for a name that is only a note, and for nil' do
      expect(described_class.without_note('(Hoster)')).to eq('')
      expect(described_class.without_note(nil)).to eq('')
    end
  end

  it 'is the normalizer MeetingParticipant uses (delegation, not a copy)' do
    allow(described_class).to receive(:normalize).and_call_original

    MeetingParticipant.normalize_name('  Jürgen   Müller ')

    expect(described_class).to have_received(:normalize).with('  Jürgen   Müller ')
  end
end
