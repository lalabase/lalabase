# frozen_string_literal: true

module Lalabase
  # Detects whether a piece of text is German or English using a pure-Ruby
  # heuristic. Designed for the Lalabase chat flow where languages are
  # limited to %w[de en] and detection happens on the first substantive
  # user message.
  #
  # Two signals:
  #   1. German-specific letters: ä, ö, ü, ß
  #   2. German short-word frequencies (article/verb stems that appear in
  #      almost any non-trivial German sentence)
  #
  # If either signal crosses a threshold relative to text length, we
  # classify as German. Default fallback is English (the most common
  # language for technical chats + the project's working locale).
  #
  # Returns a value from SUPPORTED_LANGUAGES, never nil.
  class LanguageDetector
    # Canonical set lives in Lalabase::Languages; aliased here for the contract
    # specs + the call-site fallbacks below.
    SUPPORTED_LANGUAGES = Lalabase::Languages::SUPPORTED
    DEFAULT_LANGUAGE    = Lalabase::Languages::DEFAULT

    GERMAN_LETTERS  = %w[ä ö ü ß].freeze
    GERMAN_WORDS    = %w[
      der die das den dem des ein eine einen einer eines
      und oder aber nicht ist sind war waren wird werden
      ich du wir ihr sie mir mich dir dich uns euch
      mit von bei zu auf für aus über unter
      hat habe haben hatte hatten kann können könnte
      wie was wann wo warum wer wen wem
      nicht auch nur sehr noch schon
    ].freeze

    # Below this many letters we don't trust the signal — fall back.
    MIN_TEXT_LENGTH = 8

    # Required ratio of German indicators to classify as German.
    GERMAN_LETTER_RATIO_THRESHOLD = 0.01 # ≥1% of letters are ä/ö/ü/ß
    GERMAN_WORD_RATIO_THRESHOLD   = 0.10 # ≥10% of tokens are German short words

    def self.call(text)
      new(text).call
    end

    def initialize(text)
      @text = text.to_s
    end

    def call
      return DEFAULT_LANGUAGE if too_short?

      return 'de' if german_letter_ratio >= GERMAN_LETTER_RATIO_THRESHOLD
      return 'de' if german_word_ratio   >= GERMAN_WORD_RATIO_THRESHOLD

      DEFAULT_LANGUAGE
    end

    private

    def too_short?
      letters.length < MIN_TEXT_LENGTH
    end

    def letters
      @letters ||= @text.downcase.gsub(/[^\p{L}]/, '')
    end

    def tokens
      @tokens ||= @text.downcase.scan(/\p{L}+/)
    end

    def german_letter_ratio
      return 0.0 if letters.empty?

      hits = GERMAN_LETTERS.sum { |ch| letters.count(ch) }
      hits.to_f / letters.length
    end

    def german_word_ratio
      return 0.0 if tokens.empty?

      hits = tokens.count { |t| GERMAN_WORDS.include?(t) }
      hits.to_f / tokens.length
    end
  end
end
