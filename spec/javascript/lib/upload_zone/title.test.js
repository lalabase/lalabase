// What: the title a file suggests and when a field may take it
//   (lib/upload_zone/title.js, S4 of doc/dokumentansicht_plan.md).
// Type: node:test unit spec; no DOM.
// Why: an empty first field is how "asdfasdf" happens (the template's 2.1),
//   and a suggestion that overwrote a typed title would be worse than none.
import { test } from "node:test"
import assert from "node:assert/strict"
import { titleFromFilename, mayPrefill } from "../../../../app/javascript/lib/upload_zone/title.js"

test("titleFromFilename drops the extension and nothing else", () => {
  assert.equal(titleFromFilename("Angebot_v2.final.pdf"), "Angebot_v2.final")
  assert.equal(titleFromFilename("Plan.docx"), "Plan")
  assert.equal(titleFromFilename("  Plan .docx "), "Plan")
})

test("titleFromFilename keeps a name without an extension, and a dotfile", () => {
  assert.equal(titleFromFilename("README"), "README")
  assert.equal(titleFromFilename(".gitignore"), ".gitignore")
  assert.equal(titleFromFilename(""), "")
  assert.equal(titleFromFilename(undefined), "")
})

test("titleFromFilename drops a folder part a browser may carry", () => {
  assert.equal(titleFromFilename("C:\\fakepath\\Plan.pdf"), "Plan")
  assert.equal(titleFromFilename("folder/Plan.pdf"), "Plan")
})

test("mayPrefill allows an empty field and the last suggestion, never typed words", () => {
  assert.equal(mayPrefill("", ""), true)
  assert.equal(mayPrefill("   ", "Plan"), true)
  assert.equal(mayPrefill("Plan", "Plan"), true)
  assert.equal(mayPrefill("Mein Titel", "Plan"), false)
  assert.equal(mayPrefill(undefined, ""), true)
})
