// What: the state model of the filter bar (lib/filter_bar/change_set.js).
// Type: node:test unit spec, no DOM.
// Why: the save row names a change ("„in Arbeit" wurde entfernt.") and decides
//   whether a view is dirty. Both rest on one comparison rule: a category the
//   reader emptied is no condition, a value taken away and put back is no
//   change, and the reader's edit replaces the saved category as a whole.
//   Getting that wrong shows a dot and a sentence for nothing, or hides a real
//   change. The server applies the same rule (AdHocFilterable), so the cases
//   here mirror the request specs.
import { test } from "node:test"
import assert from "node:assert/strict"
import {
  normalise, effectiveConditions, orderedCategories, isDirty,
  describeChange, applyEdit, conditionCount
} from "../../../../app/javascript/lib/filter_bar/change_set.js"

const saved = {
  filters: { status: ["offen", "in Arbeit"], assignee: ["me"] },
  operators: { status: "or", assignee: "or" }
}

test("normalise drops empty categories, sorts, dedupes and defaults the operator", () => {
  const out = normalise({ filters: { b: ["2", "1", "2"], a: [], c: [""] }, operators: {} })
  assert.deepEqual(out, { filters: { b: ["1", "2"] }, operators: { b: "or" } })
})

test("normalise reads values as strings, the way the address carries them", () => {
  assert.deepEqual(normalise({ filters: { n: [3, "1"] } }).filters, { n: ["1", "3"] })
})

test("the effective set is the saved set while the reader changed nothing", () => {
  // effective keeps the stored order (a pill never jumps); normalise sorts.
  assert.deepEqual(normalise(effectiveConditions({ saved })), normalise(saved))
  assert.deepEqual(effectiveConditions({ saved }).filters.status, ["offen", "in Arbeit"])
})

test("a reader's edit replaces the saved category as a whole, other categories stay", () => {
  const effective = effectiveConditions({ saved, adHoc: { filters: { status: ["offen"] }, operators: {} } })
  assert.deepEqual(effective.filters, { status: ["offen"], assignee: ["me"] })
})

test("a dropped saved category disappears; a category dropped and re-added counts again", () => {
  assert.deepEqual(effectiveConditions({ saved, dropped: ["status"] }).filters, { assignee: ["me"] })
  const readded = effectiveConditions({ saved, dropped: ["status"], adHoc: { filters: { status: ["wartet"] } } })
  assert.deepEqual(readded.filters, { status: ["wartet"], assignee: ["me"] })
})

test("a new ad-hoc category joins the saved ones; its operator is kept", () => {
  const effective = effectiveConditions({ saved, adHoc: { filters: { tag: ["bug", "ui"] }, operators: { tag: "and" } } })
  assert.deepEqual(effective.filters.tag, ["bug", "ui"])
  assert.equal(effective.operators.tag, "and")
  assert.equal(effective.operators.status, "or")
})

test("categories keep the saved order first, then the reader's order of adding", () => {
  const order = orderedCategories({ saved, adHoc: { filters: { tag: ["x"], status: ["offen"], creator: ["me"] } } })
  assert.deepEqual(order, ["status", "assignee", "tag", "creator"])
})

test("nothing is dirty while nothing changed, whatever the order of the values", () => {
  assert.equal(isDirty(saved, effectiveConditions({ saved })), false)
  const reordered = { filters: { assignee: ["me"], status: ["in Arbeit", "offen"] }, operators: {} }
  assert.equal(isDirty(saved, reordered), false)
})

test("a value taken away and put back is no change; an emptied category on the base view is no condition", () => {
  const backAgain = effectiveConditions({ saved, adHoc: { filters: { status: ["in Arbeit", "offen"] } } })
  assert.equal(isDirty(saved, backAgain), false)
  assert.equal(isDirty({}, { filters: { status: [] } }), false)
  assert.equal(conditionCount({ filters: { status: [], tag: ["a"] } }), 1)
})

test("a removed value, an added value and a changed operator are each dirty", () => {
  assert.equal(isDirty(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen"] } } })), true)
  assert.equal(isDirty(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen", "in Arbeit", "wartet"] } } })), true)
  assert.equal(isDirty(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen", "in Arbeit"] }, operators: { status: "not" } } })), true)
})

test("describeChange names the removed value", () => {
  const change = describeChange(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen"] } } }))
  assert.equal(change.kind, "removed")
  assert.deepEqual(change.removed, [{ category: "status", value: "in Arbeit" }])
  assert.deepEqual(change.added, [])
})

test("describeChange lists two removed values across categories", () => {
  const change = describeChange(saved, { filters: { status: ["offen"] }, operators: {} })
  assert.equal(change.kind, "removed")
  assert.deepEqual(change.removed.map(r => r.value).sort(), ["in Arbeit", "me"])
})

test("describeChange names an added value", () => {
  const change = describeChange(saved, effectiveConditions({ saved, adHoc: { filters: { tag: ["bug"] } } }))
  assert.equal(change.kind, "added")
  assert.deepEqual(change.added, [{ category: "tag", value: "bug" }])
})

test("removed and added together, or an operator alone, are 'changed'", () => {
  const mixed = describeChange(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen", "wartet"] } } }))
  assert.equal(mixed.kind, "changed")
  const operatorOnly = describeChange(saved, effectiveConditions({ saved, adHoc: { filters: { status: ["offen", "in Arbeit"] }, operators: { status: "not" } } }))
  assert.equal(operatorOnly.kind, "changed")
  assert.equal(describeChange(saved, effectiveConditions({ saved })).kind, "none")
})

test("applyEdit stores the category's complete new values and leaves 'or' out of the address", () => {
  const next = applyEdit({ saved, adHoc: {}, dropped: [] }, "status", ["offen"], "or")
  assert.deepEqual(next.adHoc, { filters: { status: ["offen"] }, operators: {} })
  assert.deepEqual(next.dropped, [])
  const withNot = applyEdit(next, "status", ["offen"], "not")
  assert.equal(withNot.adHoc.operators.status, "not")
})

test("emptying a saved category drops it; adding a value to it takes it off the dropped list", () => {
  const dropped = applyEdit({ saved, adHoc: {}, dropped: [] }, "status", [], "or")
  assert.deepEqual(dropped.dropped, ["status"])
  assert.equal("status" in dropped.adHoc.filters, false)
  const back = applyEdit(dropped, "status", ["wartet"], "or")
  assert.deepEqual(back.dropped, [])
  assert.deepEqual(back.adHoc.filters.status, ["wartet"])
})

test("emptying a category of the reader's own just deletes it, nothing is dropped", () => {
  const start = applyEdit({ saved, adHoc: {}, dropped: [] }, "tag", ["bug"], "and")
  const gone = applyEdit(start, "tag", [], "and")
  assert.deepEqual(gone.adHoc, { filters: {}, operators: {} })
  assert.deepEqual(gone.dropped, [])
})

test("an edit that lands on the saved condition again leaves the address", () => {
  const away = applyEdit({ saved, adHoc: {}, dropped: [] }, "status", ["offen"], "or")
  assert.deepEqual(away.adHoc.filters, { status: ["offen"] })
  const back = applyEdit({ saved, ...away }, "status", ["in Arbeit", "offen"], "or")
  assert.deepEqual(back.adHoc, { filters: {}, operators: {} })
  assert.deepEqual(back.dropped, [])
  // The same values with another operator are still an edit.
  const flipped = applyEdit({ saved, ...away }, "status", ["in Arbeit", "offen"], "not")
  assert.deepEqual(flipped.adHoc.filters, { status: ["in Arbeit", "offen"] })
})

test("a saved and-operator survives an edit elsewhere", () => {
  const e = effectiveConditions({ saved: { filters: { tag: ["a", "b"] }, operators: { tag: "and" } }, adHoc: { filters: { creator: ["me"] } } })
  assert.equal(e.operators.tag, "and")
})

test("an operator without values changes nothing", () => {
  const e = effectiveConditions({ saved, adHoc: { filters: {}, operators: { status: "not" } } })
  assert.equal(e.operators.status, "or")
})

test("an edit with only blank values removes the category", () => {
  const e = effectiveConditions({ saved, adHoc: { filters: { status: [""] } } })
  assert.equal("status" in e.filters, false)
})

test("a scalar value from an old bookmark counts as one value instead of throwing", () => {
  assert.deepEqual(normalise({ filters: { status: "open" } }).filters, { status: ["open"] })
  assert.deepEqual(effectiveConditions({ adHoc: { filters: { status: "open" } } }).filters, { status: ["open"] })
})
