// What: the comparable snapshot behind "unsaved changes?" on the ticket writing surface.
// Type: node:test unit spec (no DOM; FormData is fed as [name, value] pairs).
// Why: Escape must close an untouched form at once and ask when anything changed; the
//   snapshot must ignore the fields Rails rotates on its own (authenticity token) and
//   must notice a chosen file without reading its bytes.
import { test } from "node:test"
import assert from "node:assert/strict"
import { snapshotEntries, VOLATILE_FIELDS } from "../../../app/javascript/lib/form_snapshot.js"

test("is stable for the same values regardless of order", () => {
  const a = snapshotEntries([["ticket[title]", "A"], ["ticket[content]", "<p>x</p>"]])
  const b = snapshotEntries([["ticket[content]", "<p>x</p>"], ["ticket[title]", "A"]])
  assert.equal(a, b)
})

test("changes when a value changes", () => {
  const a = snapshotEntries([["ticket[title]", "A"]])
  const b = snapshotEntries([["ticket[title]", "B"]])
  assert.notEqual(a, b)
})

test("ignores the fields Rails rotates by itself", () => {
  const a = snapshotEntries([["authenticity_token", "1"], ["ticket[title]", "A"]], { ignore: VOLATILE_FIELDS })
  const b = snapshotEntries([["authenticity_token", "2"], ["ticket[title]", "A"]], { ignore: VOLATILE_FIELDS })
  assert.equal(a, b)
})

test("notices a chosen file by name and size without reading it", () => {
  const empty = { name: "", size: 0 }
  const chosen = { name: "shot.png", size: 1234 }
  const a = snapshotEntries([["ticket[ticket_document_files][]", empty]])
  const b = snapshotEntries([["ticket[ticket_document_files][]", chosen]])
  assert.notEqual(a, b)
  assert.match(b, /file:shot\.png:1234/)
})

test("treats null and undefined values as empty strings", () => {
  assert.equal(snapshotEntries([["a", null]]), snapshotEntries([["a", undefined]]))
})
