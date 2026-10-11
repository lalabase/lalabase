// What: the pill of a yes/no category (lib/filter_bar/chip_renderer.js,
//   buildChipHtml), the waiting states "Wartet" and "Hält auf"
//   (doc/ticket_relations_plan.md, revision 4, §9).
// Type: node:test unit spec.
// Why: such a category has one option, the flag. Rendered like every other
//   category its pill read "Wartet: Wartet" and, negated, "Wartet: nicht
//   Wartet". A category
//   that carries flag_labels says its operator as "ja" / "nein" instead; the
//   other categories keep "nicht" and their value tiles.
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
const { buildChipHtml } = await import("../../../../app/javascript/lib/filter_bar/chip_renderer.js")

const waiting = {
  key: "waiting",
  label: "Wartet",
  options: [{ value: "true", label: "Wartet" }],
  flag_labels: { yes: "ja", no: "nein" }
}
const status = { key: "status", label: "Status", options: [{ value: "offen", label: "offen" }] }

const render = (filters, operators = {}) => buildChipHtml({
  effective: { filters, operators },
  order: Object.keys(filters),
  categories: [waiting, status],
  connectors: { connector_not: "nicht", connector_and: "und", connector_or: "oder" },
  editable: () => true
})

// The pill's readable text, tags and whitespace folded away. A tag ends at the
// first ">" outside quotes: data-action carries "click->filter-bar#...".
const text = (html) => html.replace(/<(?:[^>"']|"[^"]*"|'[^']*')*>/g, " ").replace(/\s+/g, " ").trim()

test("a yes/no category says 'ja' for 'ist'", () => {
  assert.equal(text(render({ waiting: ["true"] })), "Wartet: ja")
})

test("a yes/no category says 'nein' for 'ist nicht', without 'nicht' in front", () => {
  assert.equal(text(render({ waiting: ["true"] }, { waiting: "not" })), "Wartet: nein")
})

test("the word stands in a value tile, like every other value", () => {
  assert.match(render({ waiting: ["true"] }, { waiting: "not" }), /data-value-tile>nein</)
})

test("other categories keep 'nicht' and their value", () => {
  assert.equal(text(render({ status: ["offen"] }, { status: "not" })), "Status: nicht offen")
})

test("the words are escaped", () => {
  const html = buildChipHtml({
    effective: { filters: { waiting: ["true"] }, operators: {} },
    order: ["waiting"],
    categories: [{ ...waiting, flag_labels: { yes: "<b>ja</b>", no: "nein" } }],
    editable: () => true
  })
  assert.match(html, /&lt;b&gt;ja&lt;\/b&gt;/)
})
