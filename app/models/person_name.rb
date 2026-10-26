# frozen_string_literal: true

# The ONE name normalizer, shared by meeting participants and the people
# directory, so a person and a meeting participant with the same name match.
# Contract (mirrored in name_normalizer.js, pinned by
# spec/fixtures/name_normalization_cases.json): NFC -> trim + collapse
# whitespace -> downcase -> umlaut transliteration. Accents other than umlauts
# are only downcased.
module PersonName
  def self.normalize(value)
    return '' if value.nil?

    s = value.to_s.unicode_normalize(:nfc)
    s = s.strip.gsub(/\s+/, ' ')
    s = s.downcase
    s.gsub('ä', 'ae').gsub('ö', 'oe').gsub('ü', 'ue').gsub('ß', 'ss')
  end
end
