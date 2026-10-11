// Offline parser test — the JS counterpart of the Slice 1b spike. Runs the same
// parseParticipants used by the browser against the committed transcript fixtures
// and asserts an exact participant set per fixture (README ground truth), plus the
// ü↔ue variance the fixtures deliberately omit. Run via `npm test`.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { parseParticipants } from "../../../app/javascript/lib/meetings/participant_parser.js"
import { normalizeName } from "../../../app/javascript/lib/meetings/name_normalizer.js"

const transcript = (name) =>
  readFileSync(new URL(`../../fixtures/meeting_transcripts/${name}`, import.meta.url), "utf8")

const normSet = (names) => new Set(names.map((n) => normalizeName(n)))

// README ground truth (normalized), fixture -> expected participants.
const GROUND_TRUTH = {
  "fixture_01_vollnamen_frontmatter.md": ["Anna Ananas", "Bert Bauer", "Karl Krause"],
  "fixture_02_vornamen_ohne_frontmatter.md": ["Anna", "Bert", "Karl"],
  "fixture_03_speaker_suffixe.md": ["Karl Krause", "Anna Ananas", "Bert Bauer"],
  "fixture_04_namens_normalisierung.md": ["Karl Krause", "Bert Bauer", "Anna Ananas"],
  "fixture_05_fallstricke.md": ["Bert Bauer", "Karl Krause"]
}

for (const [file, expected] of Object.entries(GROUND_TRUTH)) {
  test(`parses ${file} to the expected participant set`, () => {
    const produced = parseParticipants(transcript(file), normalizeName)
    assert.deepEqual(normSet(produced), normSet(expected))
  })
}

test("merges ü↔ue spelling variance of the same person into one participant", () => {
  const text = [
    "**Jürgen Müller:** Ich fange an.",
    "**Anna Ananas:** Danke.",
    "**Juergen Mueller:** Und noch ein Punkt."
  ].join("\n")

  const produced = parseParticipants(text, normalizeName)
  assert.deepEqual(normSet(produced), normSet(["Jürgen Müller", "Anna Ananas"]))
})

test("returns nothing for a transcript without speaker lines", () => {
  assert.deepEqual(parseParticipants("Nur Fließtext ohne Sprecherzeilen.", normalizeName), [])
  assert.deepEqual(parseParticipants("", normalizeName), [])
})
