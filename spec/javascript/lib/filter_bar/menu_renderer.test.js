// What: the sentence the value menu shows when a category has no values
//   (lib/filter_bar/menu_renderer.js, buildValueMenuHtml).
// Type: node:test unit spec.
// Why: "Keine Optionen verfügbar" under "Tags" left the reader guessing what
//   was missing. A category that knows why it is empty says so itself
//   (empty_hint); the rest keep the general sentence.
import { test } from "node:test"
import assert from "node:assert/strict"
// The HTML encoder allocates a div on import; this one escapes like a browser's.
globalThis.document = {
  createElement: () => {
    let text = ""
    return {
      set textContent(v) { text = String(v) },
      get innerHTML() { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    }
  }
}
const { buildValueMenuHtml } = await import("../../../../app/javascript/lib/filter_bar/menu_renderer.js")

const render = (cat) => buildValueMenuHtml({
  category: cat.key,
  categories: [cat],
  activeFilters: {},
  activeOperators: {},
  labels: { no_filter_options: "Keine Optionen verfügbar" },
  operatorLabels: {},
  chipEdit: false
})

test("an empty category with its own hint shows the hint", () => {
  const html = render({ key: "tag", label: "Tags", options: [], empty_hint: "Noch keine Tags" })

  assert.match(html, /Noch keine Tags/)
  assert.doesNotMatch(html, /Keine Optionen verfügbar/)
})

test("an empty category without a hint keeps the general sentence", () => {
  const html = render({ key: "creator", label: "Ersteller", options: [] })

  assert.match(html, /Keine Optionen verfügbar/)
})

test("the hint is escaped", () => {
  const html = render({ key: "tag", label: "Tags", options: [], empty_hint: "<b>x</b>" })

  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/)
})

test("a category with values shows no hint", () => {
  const html = render({ key: "tag", label: "Tags", options: [{ value: "a", label: "a" }], empty_hint: "Noch keine Tags" })

  assert.doesNotMatch(html, /Noch keine Tags/)
})
