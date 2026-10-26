// Name normalization for meeting participants — the JS half of a contract shared
// with Ruby (PersonName.normalize). Both sides are exercised against
// spec/fixtures/name_normalization_cases.json so they cannot drift.
//
// Rule (identical to Ruby): NFC -> trim + collapse inner whitespace -> downcase
// -> umlaut transliteration (ä→ae, ö→oe, ü→ue, ß→ss). Accents other than umlauts
// are left as-is (only downcased). Keep this function dependency-free so it can be
// unit-tested under plain `node --test`.
export function normalizeName(value) {
  if (value === null || value === undefined) return ""

  let s = String(value).normalize("NFC")
  s = s.trim().replace(/\s+/g, " ")
  s = s.toLowerCase()
  return s
    .replace(/ä/g, "ae")
    .replace(/ö/g, "oe")
    .replace(/ü/g, "ue")
    .replace(/ß/g, "ss")
}
