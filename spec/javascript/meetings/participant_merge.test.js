// Merge-rule contract tests (Gespräche Slice 5) — the four cases from the plan
// §5 data-flow diagram, against the pure mergeDetections function. The LLM must
// only ever ADD suggestions: existing chips stay untouched, user-removed names
// stay gone, user-edited spellings are never renamed or duplicated. Run via
// `npm test`. normalizeName is injected by path, like participant_parser.test.js.
import { test } from "node:test"
import assert from "node:assert/strict"
import { mergeDetections } from "../../../app/javascript/lib/meetings/participant_merge.js"
import { normalizeName } from "../../../app/javascript/lib/meetings/name_normalizer.js"

const merge = (detected, existing = [], dismissed = []) =>
  mergeDetections({
    detected,
    existingKeys: new Set(existing.map(normalizeName)),
    dismissedKeys: new Set(dismissed.map(normalizeName)),
    normalize: normalizeName
  })

test("case 1 — a new name becomes a suggestion", () => {
  assert.deepEqual(merge(["Anna Ananas"]), ["Anna Ananas"])
})

test("case 2 — an existing chip is left untouched (normalized match, nothing returned)", () => {
  assert.deepEqual(merge(["Anna Ananas"], ["anna   ananas"]), [])
})

test("case 3 — a user-removed name is NOT re-added", () => {
  assert.deepEqual(merge(["Bert Bauer"], [], ["Bert Bauer"]), [])
})

test("case 4 — a user-edited spelling of the same person is neither renamed nor duplicated", () => {
  // The user edited the chip to "Jürgen Müller"; a later LLM run detects the
  // raw transcript spelling again — umlaut transliteration maps both to one
  // person, so nothing is added and the edited chip stays as the user made it.
  assert.deepEqual(merge(["Juergen Mueller"], ["Jürgen Müller"]), [])
})

test("dedupes spelling variants within one detection result", () => {
  assert.deepEqual(merge(["Anna Ananas", "anna ananas", "ANNA  ANANAS"]), ["Anna Ananas"])
})

test("drops blanks and non-name garbage instead of creating empty chips", () => {
  assert.deepEqual(merge(["", "   ", null, undefined, "Bert Bauer"]), ["Bert Bauer"])
})

test("collapses inner whitespace of returned names (chip/display convention)", () => {
  assert.deepEqual(merge(["Bert   Bauer"]), ["Bert Bauer"])
})

test("all four cases combined in one run", () => {
  const detected = ["Anna Ananas", "Bert Bauer", "Karl Krause", "Juergen Mueller"]
  const existing = ["Anna Ananas", "Jürgen Müller"] // case 2 + case 4 (edited spelling)
  const dismissed = ["Karl Krause"] // case 3

  assert.deepEqual(merge(detected, existing, dismissed), ["Bert Bauer"]) // case 1
})

test("returns an empty list for a missing/empty detection result", () => {
  assert.deepEqual(merge(undefined), [])
  assert.deepEqual(merge([]), [])
})
