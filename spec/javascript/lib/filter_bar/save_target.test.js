// What: the folder target a type condition becomes (lib/filter_bar/save_target.js).
// Type: node:test unit spec.
// Why: this value fixes the scope of every folder saved from the knowledge
//   list for good. One type with a folder kind becomes it; two types, or a
//   type without a folder kind (meetings), make a folder of all types, and
//   the reader is told so before the save (typeWidened).
import { test } from "node:test"
import assert from "node:assert/strict"
import { targetForTypes, typeWidened } from "../../../../app/javascript/lib/filter_bar/save_target.js"

const targets = { note: "Note", document: "Document", meeting: null }

test("no type condition: no target of its own (the server decides)", () => {
  assert.equal(targetForTypes([], targets), null)
  assert.equal(targetForTypes(undefined, targets), null)
  assert.equal(typeWidened([], targets), false)
})

test("one type with a folder kind becomes the target, nothing widens", () => {
  assert.equal(targetForTypes(["note"], targets), "Note")
  assert.equal(targetForTypes(["document"], targets), "Document")
  assert.equal(typeWidened(["note"], targets), false)
})

test("one type without a folder kind is a folder of all types, and says so", () => {
  assert.equal(targetForTypes(["meeting"], targets), "All")
  assert.equal(typeWidened(["meeting"], targets), true)
})

test("two types are a folder of all types, and say so", () => {
  assert.equal(targetForTypes(["note", "document"], targets), "All")
  assert.equal(typeWidened(["note", "document"], targets), true)
})

test("a type the map does not know is All, not a crash", () => {
  assert.equal(targetForTypes(["bogus"], targets), "All")
  assert.equal(targetForTypes(["note"]), "All")
  assert.equal(typeWidened(["bogus"], targets), true)
})
