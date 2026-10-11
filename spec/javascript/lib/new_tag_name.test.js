// What: the offer of a new tag in the bulk panel's tags layer.
// Type: node:test unit spec, no browser.
// Why: the panel must spell a typed name the way the server stores it
//   (Tag.normalize_name), must not offer a second tag for one that exists in
//   another case, and must not offer a name the server refuses.
import { test } from "node:test"
import assert from "node:assert/strict"
import { listPosition, namesToList, newTagOffer, normalizeTagName } from "../../../app/javascript/lib/new_tag_name.js"

const limits = { existing: ["backend", "doku"], maxLength: 30, separator: "," }

test("spells a name the way the server stores it", () => {
  assert.equal(normalizeTagName("  Kunde-X "), "kunde-x")
  assert.equal(normalizeTagName(undefined), "")
})

test("offers nothing for blanks and the existing tag for another spelling", () => {
  assert.deepEqual(newTagOffer("   ", limits), { name: "", state: "none" })
  assert.deepEqual(newTagOffer(" Backend", limits), { name: "backend", state: "exists" })
})

test("offers a new tag up to the limit, and refuses one over it or with a comma", () => {
  assert.equal(newTagOffer("a".repeat(30), limits).state, "new")
  assert.equal(newTagOffer("a".repeat(31), limits).state, "invalid")
  assert.equal(newTagOffer("kunde,x", limits).state, "invalid")
  assert.deepEqual(newTagOffer("Kunde-X", limits), { name: "kunde-x", state: "new" })
})

test("lists only the given names the layer does not list yet, sorted and once", () => {
  assert.deepEqual(namesToList(["backend", "doku"], ["zeta", "doku", "alpha", "zeta", ""]), ["alpha", "zeta"])
  assert.deepEqual(namesToList(["backend"], []), [])
})

test("puts a name before the first listed name that sorts after it", () => {
  assert.equal(listPosition(["backend", "doku"], "alpha"), 0)
  assert.equal(listPosition(["backend", "doku"], "cloud"), 1)
  assert.equal(listPosition(["backend", "doku"], "zeta"), 2)
  assert.equal(listPosition([], "zeta"), 0)
})

// The server counts characters (Ruby String#length, code points); JavaScript's
// length counts UTF-16 units, so an emoji weighs two there (review of #926).
test("counts an emoji as one character, like the server", () => {
  const rocket = "\u{1F680}"
  assert.equal(newTagOffer("a".repeat(29) + rocket, limits).state, "new")
  assert.equal(newTagOffer("a".repeat(30) + rocket, limits).state, "invalid")
})
