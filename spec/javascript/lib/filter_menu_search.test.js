import test from "node:test"
import assert from "node:assert"
import { readFileSync } from "node:fs"
import { searchTerm, optionMatches, showsEmptyNotice } from "../../../app/javascript/lib/filter_menu_search.js"

// ⚠️ An empty term matches EVERYTHING. The field sits in a menu that lists every
// option without JavaScript, so the inverted rule would make an untouched field
// hide the whole menu -- and nothing on the server side can see that happen.
test("an empty or blank term matches every option", () => {
  assert.equal(optionMatches("Jour fixe", searchTerm("")), true)
  assert.equal(optionMatches("Jour fixe", searchTerm("   ")), true)
  assert.equal(optionMatches("Jour fixe", searchTerm(null)), true)
  assert.equal(optionMatches("", searchTerm("")), true)
})

test("a term matches on any part of the text, case-insensitively", () => {
  assert.equal(optionMatches("#42 / Kasse defekt", searchTerm("kasse")), true)
  assert.equal(optionMatches("#42 / Kasse defekt", searchTerm("KASSE")), true)
  assert.equal(optionMatches("#42 / Kasse defekt", searchTerm("42")), true)
  assert.equal(optionMatches("#42 / Kasse defekt", searchTerm("Rechnung")), false)
})

// The case S6 exists for: two meetings of the same title, told apart only by the
// project name the option carries beside them. Matching the title alone would
// leave the reader with two identical lines and no way to choose.
test("the project name beside a subject is part of what is matched", () => {
  const shop = "Jour fixe Shop Relaunch"
  const wartung = "Jour fixe Wartung"

  assert.equal(optionMatches(shop, searchTerm("shop")), true)
  assert.equal(optionMatches(wartung, searchTerm("shop")), false)
  assert.equal(optionMatches(shop, searchTerm("jour")), true)
  assert.equal(optionMatches(wartung, searchTerm("jour")), true)
})

// n-1 / n / n+1 around the one boundary the notice has.
test("the nothing-found line appears only when no option is left", () => {
  assert.equal(showsEmptyNotice(0), true)
  assert.equal(showsEmptyNotice(1), false)
  assert.equal(showsEmptyNotice(2), false)
})

test("a term is trimmed and lowercased once, for the whole loop", () => {
  assert.equal(searchTerm("  Kasse  "), "kasse")
  assert.equal(searchTerm(""), "")
  assert.equal(searchTerm(undefined), "")
})

// ⚠️ The MECHANISM, not just the rule. The rule above was right the whole time
// and the field was still dead: the controller wrote el.hidden, and Tailwind's
// preflight writes that attribute as `[hidden]:where(...)`, which :where() keeps
// at (0,1,0) -- the same specificity as the `.flex` every option row carries,
// and `.flex` comes first, so the later `.hidden` utility is what actually wins.
// The options were marked hidden and stayed on screen at full height.
//
// These pure functions could not see that, and neither could a spec that read
// el.hidden back. So this pins what the controller must DO with the answer.
test("hiding an option is a class, never the hidden property", () => {
  const source = readFileSync(
    new URL("../../../app/javascript/controllers/filter_menu_search_controller.js", import.meta.url),
    "utf8"
  )

  assert.match(source, /classList\.toggle\(HIDDEN_CLASS/,
               "the controller must toggle a class")
  assert.doesNotMatch(source, /\.hidden\s*=/,
                      "assigning el.hidden marks an option hidden and leaves it visible")
})
