// JS half of the name-normalization contract. Loads the SAME fixture file as
// spec/models/meeting_participant_spec.rb, so normalizeName (JS) and
// MeetingParticipant.normalize_name (Ruby) cannot drift. Run via `npm test`.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { normalizeName } from "../../../app/javascript/lib/meetings/name_normalizer.js"

const fixture = JSON.parse(
  readFileSync(new URL("../../fixtures/name_normalization_cases.json", import.meta.url))
)

for (const c of fixture.cases) {
  test(`normalizes ${JSON.stringify(c.input)} -> ${JSON.stringify(c.expected)} (${c.why})`, () => {
    assert.equal(normalizeName(c.input), c.expected)
  })
}

test("treats null/undefined as empty", () => {
  assert.equal(normalizeName(null), "")
  assert.equal(normalizeName(undefined), "")
})
