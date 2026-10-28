// What: the pure part of the additional details in the people form
//   (lib/person_details.js).
// Why:  the server orders the rows by their index and merges two rows that
//   share one; the kinds and the limit come from the server, so an unknown
//   kind must not break a row.
import { test } from "node:test"
import assert from "node:assert/strict"
import { nextIndex, fillIndex, canAdd, valueField, singleLine } from "../../../app/javascript/lib/person_details.js"

test("a new row takes the index above the highest present one", () => {
  assert.equal(nextIndex([]), 0)
  assert.equal(nextIndex(["0", "1"]), 2)
  assert.equal(nextIndex(["0", "7", "3"]), 8)
})

test("ignores anything that is not an index", () => {
  assert.equal(nextIndex(["__INDEX__", undefined, "-1", "2a", ""]), 0)
  assert.equal(nextIndex(["4", "abc"]), 5)
})

test("fills every placeholder of the template", () => {
  const html = '<select name="person[additional_details][__INDEX__][kind]"></select><input name="person[additional_details][__INDEX__][value]">'

  assert.equal(fillIndex(html, 3), '<select name="person[additional_details][3][kind]"></select><input name="person[additional_details][3][value]">')
})

test("allows a row below the limit, not at it (n-1, n, n+1)", () => {
  assert.equal(canAdd(9, 10), true)
  assert.equal(canAdd(10, 10), false)
  assert.equal(canAdd(11, 10), false)
  assert.equal(canAdd(0, NaN), false)
})

const KINDS = {
  phone: { input: "tel", maxlength: 255, list: "person-detail-suggestions-phone" },
  address: { input: "textarea", maxlength: 500, list: "person-detail-suggestions-address" },
  text: { input: "text", maxlength: 255, list: null }
}

test("gives each kind the field the server named", () => {
  assert.deepEqual(valueField(KINDS, "phone"), { tag: "input", type: "tel", maxlength: 255, list: "person-detail-suggestions-phone" })
  assert.deepEqual(valueField(KINDS, "address"), { tag: "textarea", type: null, maxlength: 500, list: "person-detail-suggestions-address" })
  assert.deepEqual(valueField(KINDS, "text"), { tag: "input", type: "text", maxlength: 255, list: null })
})

test("gives an unknown kind a plain text input, also for inherited names", () => {
  assert.deepEqual(valueField(KINDS, "fax"), { tag: "input", type: "text", maxlength: null, list: null })
  assert.deepEqual(valueField(KINDS, "constructor"), { tag: "input", type: "text", maxlength: null, list: null })
  assert.deepEqual(valueField(undefined, "phone"), { tag: "input", type: "text", maxlength: null, list: null })
})

// Review round 2, finding 1: an address switched to a single-line kind lost
// its line breaks without a separator ("Musterstraße 112345 Berlin").
test("joins the lines of a multi-line value for a single-line field", () => {
  assert.equal(singleLine("Musterstraße 1\n12345 Berlin"), "Musterstraße 1, 12345 Berlin")
  assert.equal(singleLine(" A \r\n\r\n B \r C "), "A, B, C")
  assert.equal(singleLine("eine Zeile"), "eine Zeile")
  assert.equal(singleLine(""), "")
})
