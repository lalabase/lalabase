// What: the draft of a bulk change (doc/ticket_bulk_edit_plan.md, slice 4).
// Type: node:test unit spec, no browser.
// Why: the button may act only when every added change has a value; a field
//   is added once; the draft round-trips through the selection controller as
//   plain entries.
import { test } from "node:test"
import assert from "node:assert/strict"
import { TicketBulkDraft } from "../../../app/javascript/lib/ticket_bulk_draft.js"

test("starts empty and cannot act", () => {
  const draft = new TicketBulkDraft()
  assert.equal(draft.isEmpty(), true)
  assert.equal(draft.isComplete(), false)
  assert.equal(draft.size, 0)
})

test("a field is added once, with no value yet", () => {
  const draft = new TicketBulkDraft()
  assert.equal(draft.add("status", "single"), true)
  assert.equal(draft.add("status", "single"), false)
  assert.equal(draft.size, 1)
  assert.deepEqual(draft.get("status"), { field: "status", kind: "single", value: null })
  assert.equal(draft.isComplete(), false)
})

test("complete once every added change has a value", () => {
  const draft = new TicketBulkDraft()
  draft.add("status", "single")
  draft.add("reviewed", "boolean")
  draft.setValue("status", "wip")
  assert.equal(draft.isComplete(), false)
  draft.setValue("reviewed", "false")
  assert.equal(draft.isComplete(), true)
  draft.setValue("status", "")
  assert.equal(draft.isComplete(), false, "an emptied control is no value")
})

test("removing a field drops it and its value", () => {
  const draft = new TicketBulkDraft()
  draft.add("status", "single")
  draft.setValue("status", "wip")
  assert.equal(draft.remove("status"), true)
  assert.equal(draft.remove("status"), false)
  assert.equal(draft.has("status"), false)
  assert.equal(draft.setValue("status", "x"), false)
})

test("round-trips through plain entries, in order", () => {
  const draft = new TicketBulkDraft()
  draft.add("status", "single")
  draft.add("due_date", "date")
  draft.setValue("due_date", "2026-09-30")
  const copy = TicketBulkDraft.from(draft.serialize())
  assert.deepEqual(copy.fields(), ["status", "due_date"])
  assert.equal(copy.get("due_date").value, "2026-09-30")
  copy.setValue("status", "open")
  assert.equal(draft.get("status").value, null, "the copy is its own")
  assert.deepEqual(TicketBulkDraft.from(null).serialize(), [])
})

// Slice 5: the multi-valued kinds and the date clear.

test("a multi field holds plus and minus, and is complete with either", () => {
  const draft = new TicketBulkDraft()
  draft.add("tags", "multi")
  assert.deepEqual(draft.get("tags"), { field: "tags", kind: "multi", add: [], remove: [] })
  assert.equal(draft.isComplete(), false)
  draft.addValue("tags", "backend")
  assert.equal(draft.valueState("tags", "backend"), "add")
  assert.equal(draft.isComplete(), true)
  draft.removeValue("tags", "backend")
  assert.equal(draft.valueState("tags", "backend"), "remove")
  assert.deepEqual(draft.get("tags").add, [])
  draft.clearValue("tags", "backend")
  assert.equal(draft.valueState("tags", "backend"), null)
  assert.equal(draft.isComplete(), false)
})

test("a value is listed once however often it is added", () => {
  const draft = new TicketBulkDraft()
  draft.add("tags", "multi")
  draft.addValue("tags", "a")
  draft.addValue("tags", "a")
  draft.removeValue("tags", "b")
  draft.removeValue("tags", "b")
  assert.deepEqual(draft.get("tags").add, ["a"])
  assert.deepEqual(draft.get("tags").remove, ["b"])
  assert.equal(draft.setValue("tags", "x"), false, "a multi field takes no single value")
})

test("a date can be cleared, and a value ends the clear", () => {
  const draft = new TicketBulkDraft()
  draft.add("due_date", "date")
  draft.setClear("due_date")
  assert.equal(draft.get("due_date").clear, true)
  assert.equal(draft.isComplete(), true)
  draft.setValue("due_date", "2026-09-30")
  assert.equal(draft.get("due_date").clear, undefined)
  assert.equal(draft.get("due_date").value, "2026-09-30")
  draft.setClear("due_date", false)
  assert.equal(draft.isComplete(), true)
})

test("the multi lists survive the round trip as their own copies", () => {
  const draft = new TicketBulkDraft()
  draft.add("tags", "multi")
  draft.addValue("tags", "a")
  const copy = TicketBulkDraft.from(draft.serialize())
  copy.addValue("tags", "b")
  assert.deepEqual(draft.get("tags").add, ["a"])
  assert.deepEqual(copy.get("tags").add, ["a", "b"])
})

// The designer's review (08.09.2026): a row without a value is no change, and
// the rows keep the catalogue's order whatever the order of adding.

test("a row without a value does not count, is not sent, and one value is enough to act", () => {
  const draft = new TicketBulkDraft()
  draft.add("status", "single")
  draft.add("priority", "single")
  draft.add("assignees", "multi")
  assert.equal(draft.size, 3)
  assert.equal(draft.changeCount, 0)
  assert.equal(draft.hasChange(), false)
  draft.addValue("assignees", "u1")
  assert.equal(draft.changeCount, 1)
  assert.equal(draft.hasChange(), true)
  assert.equal(draft.isComplete(), false, "two rows are still open")
  assert.deepEqual(draft.serialize(true).map((entry) => entry.field), ["assignees"])
  assert.equal(draft.serialize().length, 3, "kept with the open rows")
})

test("the rows keep the catalogue's order, whatever the order of adding", () => {
  const order = ["status", "priority", "due_date", "tags", "assignees"]
  const draft = new TicketBulkDraft([], order)
  draft.add("assignees", "multi")
  draft.add("priority", "single")
  draft.add("status", "single")
  assert.deepEqual(draft.fields(), ["status", "priority", "assignees"])
  assert.equal(draft.indexOf("priority"), 1)
  draft.add("unknown", "single")
  assert.deepEqual(draft.fields(), ["status", "priority", "assignees", "unknown"], "unknown fields go last")
  const restored = TicketBulkDraft.from([{ field: "assignees", kind: "multi", add: ["u1"], remove: [] }, { field: "status", kind: "single", value: "open" }], order)
  assert.deepEqual(restored.fields(), ["status", "assignees"])
})
