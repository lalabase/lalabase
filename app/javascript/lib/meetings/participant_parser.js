// Offline meeting-transcript participant parser — pure, client-only, no network.
// Extracts speaker labels from `**Label:**` markdown speaker lines and returns
// suggested participant display names. Ported verbatim from the Slice 1b spike
// (100% micro-F1 on spec/fixtures/meeting_transcripts). Unit-tested under
// `node --test` against those fixtures.
//
// The `normalize` fn is injected (not imported) on purpose: a cross-module import
// would force a choice between a browser-only bare specifier and a node-only
// relative path. Callers pass name_normalizer's normalizeName — the browser via a
// pinned specifier, node via a filesystem path — so there is exactly one
// normalization implementation and no import that breaks in either environment.
//
// Algorithm:
//   1. line scan for `**Label:**` at line start
//   2. strip a trailing `(Speaker N)` / `(Sprecher N)` diarisation suffix
//   3. drop non-speaker/group bold labels (Wichtig, Fazit, Alle, …) via STOPWORDS
//   4. dedup by normalized name, keeping the richest (longest) display spelling
//   5. coreference merge: a bare first name folds into the UNIQUE full name that
//      shares its first token (Karl -> Karl Krause); ambiguous/zero matches stay.

// German non-speaker bold labels + group labels that must never become people.
// Stored already in normalized form (plain lowercase ASCII), so they match
// normalize(label) without needing normalize() at module load.
const STOPWORDS = new Set([
  "alle", "beide", "gruppe", "team", "moderator", "moderation",
  "wichtig", "fazit", "hinweis", "achtung", "anmerkung", "notiz", "notizen",
  "aufgabe", "aufgaben", "todo", "ergebnis", "ergebnisse", "beschluss",
  "info", "information", "update", "thema", "themen", "datum", "ort",
  "zeit", "uhrzeit", "dauer", "teilnehmer", "anwesend", "abwesend", "agenda",
  "tagesordnung", "protokoll", "zusammenfassung", "summary", "ziel", "ziele",
  "entscheidung", "entscheidungen", "frage", "fragen", "antwort", "kommentar",
  "quelle", "quellen", "anlage", "anlagen"
])

const SPEAKER_LINE = /^\s*\*\*\s*([^*:]+?)\s*:\s*\*\*/
const SPEAKER_SUFFIX = /\s*\((?:speaker|sprecher)\s*\d+\)\s*$/i

const firstToken = (name) => name.trim().split(/\s+/)[0]

// Returns an array of suggested participant display names (deduped, merged).
// `normalize` must be name_normalizer's normalizeName (injected — see header).
export function parseParticipants(text, normalize) {
  if (!text) return []

  const raw = []
  for (const line of String(text).split(/\r?\n/)) {
    const m = SPEAKER_LINE.exec(line)
    if (!m) continue

    const label = m[1].replace(SPEAKER_SUFFIX, "").trim()
    if (!label) continue
    if (STOPWORDS.has(normalize(label))) continue

    raw.push(label)
  }

  // Dedup by normalized name; keep the longest display spelling seen.
  const byNorm = new Map()
  for (const label of raw) {
    const n = normalize(label)
    const current = byNorm.get(n)
    if (current === undefined || label.length > current.length) byNorm.set(n, label)
  }
  const names = Array.from(byNorm.values())

  // Coreference merge: bare first name -> unique full-name variant.
  const multi = names.filter((n) => n.trim().split(/\s+/).length > 1)
  return names.filter((name) => {
    if (name.trim().split(/\s+/).length !== 1) return true

    const matches = multi.filter((full) => normalize(firstToken(full)) === normalize(name))
    return matches.length !== 1
  })
}
