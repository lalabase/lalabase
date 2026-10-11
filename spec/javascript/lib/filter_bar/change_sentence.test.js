// What: the wording of the save row and of the filter sign's title
//   (lib/filter_bar/change_sentence.js).
// Type: node:test unit spec.
// Why: the row names the change ("„in Arbeit" wurde entfernt.") and must not
//   count where it can name, nor name where a count reads better. These are
//   the six shapes the prototype settled on (Prüfstand F23, Befund 2).
import { test } from "node:test"
import assert from "node:assert/strict"
import { changeSentence, countSentence, filterSignTitle, fill, pickPlural } from "../../../../app/javascript/lib/filter_bar/change_sentence.js"

const labels = {
  change_value_removed: "„%{value}“ wurde entfernt.",
  change_two_values_removed: "„%{a}“ und „%{b}“ wurden entfernt.",
  change_values_removed: "%{count} Werte wurden entfernt.",
  change_value_added: "„%{value}“ kam dazu.",
  change_values_added: "%{count} Werte kamen dazu.",
  change_conditions_changed: "Die Bedingungen sind geändert.",
  condition_count: { one: "Eine Bedingung grenzt die Liste ein.", other: "%{count} Bedingungen grenzen die Liste ein." },
  filter_sign_title: { zero: "Filter", one: "Filter · 1 Bedingung", other: "Filter · %{count} Bedingungen" }
}
const labelFor = (_category, value) => ({ ia: "in Arbeit", w: "wartet", o: "offen" }[value] || value)
const removed = values => ({ kind: "removed", removed: values.map(value => ({ category: "status", value })), added: [] })
const added = values => ({ kind: "added", added: values.map(value => ({ category: "status", value })), removed: [] })

test("one removed value is named", () => {
  assert.equal(changeSentence(removed(["ia"]), labels, labelFor), "„in Arbeit“ wurde entfernt.")
})

test("two removed values are both named, three are counted", () => {
  assert.equal(changeSentence(removed(["ia", "w"]), labels, labelFor), "„in Arbeit“ und „wartet“ wurden entfernt.")
  assert.equal(changeSentence(removed(["ia", "w", "o"]), labels, labelFor), "3 Werte wurden entfernt.")
})

test("one added value is named, two are counted", () => {
  assert.equal(changeSentence(added(["w"]), labels, labelFor), "„wartet“ kam dazu.")
  assert.equal(changeSentence(added(["w", "o"]), labels, labelFor), "2 Werte kamen dazu.")
})

test("mixed changes get the neutral sentence, none gets nothing", () => {
  assert.equal(changeSentence({ kind: "changed", removed: [], added: [] }, labels, labelFor), "Die Bedingungen sind geändert.")
  assert.equal(changeSentence({ kind: "none", removed: [], added: [] }, labels, labelFor), "")
})

test("the base view counts its conditions with a real plural", () => {
  assert.equal(countSentence(1, labels), "Eine Bedingung grenzt die Liste ein.")
  assert.equal(countSentence(2, labels), "2 Bedingungen grenzen die Liste ein.")
})

// S5 of doc/kanban_ticket_als_bahn_plan.md: tight, the trigger is a sign and
// the title is all the word it has. Nothing set has a word of its own.
test("the filter sign's title carries the count, with a word of its own for nothing", () => {
  assert.equal(filterSignTitle(0, labels), "Filter")
  assert.equal(filterSignTitle(1, labels), "Filter · 1 Bedingung")
  assert.equal(filterSignTitle(2, labels), "Filter · 2 Bedingungen")
})

test("a plural without a zero form falls back to other at zero", () => {
  assert.equal(pickPlural({ one: "one", other: "other" }, 0), "other")
})

test("fill leaves unknown placeholders empty instead of printing them", () => {
  assert.equal(fill("a %{x} b %{y}", { x: 1 }), "a 1 b ")
  assert.equal(pickPlural("plain", 5), "plain")
})
