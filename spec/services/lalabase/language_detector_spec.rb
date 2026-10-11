# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::LanguageDetector do
  def detect(text) = described_class.call(text)

  describe 'German detection via umlauts/ß' do
    it 'detects German for a sentence with umlauts' do
      expect(detect('Können Sie mir bitte erklären, wie das funktioniert?')).to eq('de')
    end

    it 'detects German even from a single ß in long-enough text' do
      expect(detect('Das große Haus war geschlossen heute.')).to eq('de')
    end

    described_class::GERMAN_LETTERS.each do |letter|
      it "treats text containing #{letter.inspect} above the letter-ratio as German" do
        # Pad to clear MIN_TEXT_LENGTH and stay above the 1% letter ratio.
        text = "this is an english sentence with one #{letter} char"
        expect(detect(text)).to eq('de')
      end
    end
  end

  describe 'German detection via short-word density' do
    it 'detects German for a sentence built only from ASCII German words' do
      expect(detect('ich bin nicht sicher wie das funktioniert')).to eq('de')
    end

    it 'detects German for `der die das` triple' do
      expect(detect('der mann sieht die frau und das kind')).to eq('de')
    end
  end

  describe 'English detection (default fallback)' do
    it 'detects English for a plain English sentence' do
      expect(detect('How does the notification system work?')).to eq('en')
    end

    it 'detects English for a technical question' do
      expect(detect('explain the architecture of the indexer please')).to eq('en')
    end
  end

  describe 'short / pathological input — default fallback' do
    it 'returns the default for the empty string' do
      expect(detect('')).to eq(described_class::DEFAULT_LANGUAGE)
    end

    it 'returns the default for nil' do
      expect(detect(nil)).to eq(described_class::DEFAULT_LANGUAGE)
    end

    it 'returns the default for whitespace-only input' do
      expect(detect("   \n\t  ")).to eq(described_class::DEFAULT_LANGUAGE)
    end

    it 'returns the default for input below MIN_TEXT_LENGTH (one-word "hallo")' do
      # 5 letters < MIN_TEXT_LENGTH(=8): can't trust the signal, even on a
      # clearly German word.
      expect(detect('hallo')).to eq('en')
    end

    it 'classifies at exactly MIN_TEXT_LENGTH letters (n boundary)' do
      # Exactly 8 letters, all German short-words → above threshold.
      expect(detect('ich und du')).to eq('de') # 'ich' + 'und' + 'du' = 8 letters
    end

    it 'falls back at MIN_TEXT_LENGTH - 1 letters (n-1 boundary)' do
      # 7 letters → too short to trust signal → default. Catches mutation
      # `letters.length <= MIN_TEXT_LENGTH` (which would also reject n=8).
      expect(detect('ich und')).to eq('en') # 'ich' + 'und' = 6 letters → too short
      expect(detect('ich und d')).to eq('en') # 'ich' + 'und' + 'd' = 7 letters
    end

    it 'classifies at MIN_TEXT_LENGTH + 1 letters (n+1 boundary)' do
      # 9 letters of German words → above threshold.
      expect(detect('ich und wir')).to eq('de') # 3+3+3 = 9 letters
    end

    it 'falls back to en for non-letter junk' do
      expect(detect('1234567890!!!!')).to eq('en')
    end
  end

  describe 'unicode safety' do
    it 'does not crash on emoji input' do
      expect { detect('🚀💯 hello world 🎉') }.not_to raise_error
    end

    it 'does not crash on CJK input (and falls back to en, since not German)' do
      expect(detect('日本語のテストです、こんにちは世界')).to eq('en')
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::SUPPORTED_LANGUAGES).to contain_exactly('de', 'en') }
    it { expect(described_class::SUPPORTED_LANGUAGES).to be_frozen }
    it { expect(described_class::DEFAULT_LANGUAGE).to eq('en') }
    it { expect(described_class::DEFAULT_LANGUAGE).to be_in(described_class::SUPPORTED_LANGUAGES) }
    it { expect(described_class::GERMAN_LETTERS).to contain_exactly('ä', 'ö', 'ü', 'ß') }
    it { expect(described_class::GERMAN_LETTERS).to be_frozen }
    it { expect(described_class::GERMAN_WORDS).to be_frozen }
    it { expect(described_class::MIN_TEXT_LENGTH).to eq(8) }
    it { expect(described_class::GERMAN_LETTER_RATIO_THRESHOLD).to be_within(0.0001).of(0.01) }
    it { expect(described_class::GERMAN_WORD_RATIO_THRESHOLD).to be_within(0.0001).of(0.10) }
  end

  describe 'GERMAN_WORDS uses EXACT match, not substring (defense against false-positive German)' do
    # If the implementation ever changes to `tokens.any? { |w| t.include?(w) }`
    # English words containing German substrings would trip detection:
    #   'database' contains 'das'
    #   'derivative' contains 'der'
    #   'ister' contains 'ist'
    it 'does NOT classify "database derivative ister" as German (would fail under substring matching)' do
      expect(detect('database derivative ister discussion analysis')).to eq('en')
    end

    it 'matches "das" as a standalone word, not as part of "database"' do
      expect(detect('das ist der mann hier')).to eq('de') # legit German
      expect(detect('database derivative ister code analytics platform tests')).to eq('en') # contains substrings only
    end
  end

  describe 'unicode-letter tokenisation — umlauted words form single tokens' do
    # If the tokenizer regex regresses from \p{L} to [a-z], 'können' would
    # split into 'k' and 'nnen' and not match GERMAN_WORDS.include?('können').
    # Our GERMAN_WORDS only includes ASCII so this is a soft signal — but
    # umlauts still count via the letter ratio, so result should be German.
    it 'detects German via LETTER pathway alone (no GERMAN_WORDS hits in this text)' do
      # IMPORTANT: this sentence is curated to contain ZERO words from
      # GERMAN_WORDS. Earlier version included 'wir', 'wo', 'die', 'haben'
      # which made the word-pathway also trigger — meaning a mutation that
      # disabled the letter-pathway would survive.
      text = 'Möglicherweise später überprüfen Änderungen größere Auswirkungen'
      # Sanity check via the test itself: assert no GERMAN_WORDS overlap.
      tokens = text.downcase.scan(/\p{L}+/)
      overlap = tokens & described_class::GERMAN_WORDS
      expect(overlap).to be_empty, "Test setup leak: #{overlap} are in GERMAN_WORDS"

      expect(detect(text)).to eq('de')
    end
  end

  describe 'threshold boundary — letter ratio exactly at GERMAN_LETTER_RATIO_THRESHOLD (n)' do
    # 1% threshold. Build a string where exactly 1% of letters are German.
    # 100 ASCII letters + 1 ä = 101 letters total; 1/101 ≈ 0.99% (just below 1%).
    # 99 ASCII letters + 1 ä = 100 letters total; 1/100 = 1% exactly.
    it 'classifies as German when letter ratio is EXACTLY at threshold (>= 1%)' do
      ascii = 'a' * 99 # 99 ASCII letters
      text = "#{ascii}ä" # one ä, total 100 letters, ratio = 1%
      expect(detect(text)).to eq('de')
    end

    it 'falls back to English when letter ratio is just BELOW threshold' do
      ascii = 'a' * 200 # plenty of letters
      text = "#{ascii}ä" # one ä, total 201 letters, ratio ≈ 0.5% < 1%
      expect(detect(text)).to eq('en')
    end
  end

  describe 'detection NEVER returns a value outside SUPPORTED_LANGUAGES' do
    it 'always returns a member of SUPPORTED_LANGUAGES regardless of input' do
      [
        nil, '', '   ', 'hi', 'hello', '12345',
        'Können Sie helfen?', 'How are you today?',
        '🚀', '日本語', '!@#$%^&*()'
      ].each do |sample|
        expect(described_class::SUPPORTED_LANGUAGES).to include(detect(sample)),
                                                        "Input #{sample.inspect} returned #{detect(sample).inspect}"
      end
    end
  end

  describe 'class-method form mirrors instance form' do
    it 'returns the same result via .call and #call' do
      text = 'Wie funktioniert das hier eigentlich?'
      expect(described_class.call(text)).to eq(described_class.new(text).call)
    end
  end
end
