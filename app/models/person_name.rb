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

  # A name without its notes in round brackets: "J. Weber (Hoster)" ->
  # "J. Weber". A meeting participant is often written with a note about the
  # role; the note is no part of the person's name. The surname of a
  # suggestion (People::Directory.surname) and the name a new person starts
  # with in the link dialog both read it, so the two never disagree. Empty
  # when the name is only a note.
  def self.without_note(value)
    value.to_s.gsub(/\([^)]*\)/, ' ').squish
  end
end
