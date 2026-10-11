// What: the page's lane parameters in three groups and what each reader takes
//   from them (lib/lane/params.js, D9 of doc/dateivorschau_plan.md).
// Type: node:test unit spec over strings and URLs; no DOM beyond a closest() fake.
// Why: one list for every purpose was wrong twice over (the review of the plan):
//   openSelection would take ?preview=V for an open object, and the pagination
//   would drop the preview. The groups say what a selection is, what its
//   sub-state is, and what a form state is; the readers derive their rules.
import { test } from "node:test"
import assert from "node:assert/strict"
import {
  EMPTY_LANE_PARAMS, parseLaneParams, readLaneParams, laneParamNames, listPart, lanePart, withLaneState, withLanePartOf } from "../../../../app/javascript/lib/lane/params.js"

const KNOWLEDGE = JSON.stringify({ selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] })
const groups = parseLaneParams(KNOWLEDGE)

test("parseLaneParams reads the three groups and answers empty groups for nothing or nonsense", () => {
  assert.deepEqual(groups, { selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] })
  assert.deepEqual(parseLaneParams(null), EMPTY_LANE_PARAMS)
  assert.deepEqual(parseLaneParams("{not json"), EMPTY_LANE_PARAMS)
  assert.deepEqual(parseLaneParams('{"selection":["ticket_id"]}'), { selection: ["ticket_id"], preview: [], form: [], ignore: [] })
})

test("readLaneParams takes the nearest wrapper's groups, and a fallback where the page has none", () => {
  const wrapper = { dataset: { laneParams: KNOWLEDGE } }
  const row = { closest: (selector) => (selector === "[data-lane-params]" ? wrapper : null) }
  assert.deepEqual(readLaneParams(row), groups)
  const orphan = { closest: () => null }
  const fallback = { selection: ["inbox_id"], preview: [], form: [], ignore: [] }
  assert.deepEqual(readLaneParams(orphan, fallback), fallback)
  assert.deepEqual(readLaneParams(null), EMPTY_LANE_PARAMS)
})

test("the lane part is the selection and its preview; the list part is the rest, sorted, without them", () => {
  assert.deepEqual(laneParamNames(groups), ["note_id", "document_id", "preview"])
  const search = "?type=all&preview=V&search=x&document_id=D&filter%5Btag%5D%5B%5D=b&filter%5Btag%5D%5B%5D=a"
  assert.equal(listPart(search, groups), "filter%5Btag%5D%5B%5D=a&filter%5Btag%5D%5B%5D=b&search=x&type=all")
  assert.equal(listPart("?b=2&a=1", groups), listPart("?a=1&b=2", groups), "two spellings, one list part")
  assert.equal(listPart("?new=document&type=all", groups), "new=document&type=all", "a form state is a page state")
  assert.equal(listPart("?type=all&viewport=desktop", groups), "type=all", "a page-mode parameter is neither list nor lane")
  assert.deepEqual(lanePart(search, groups), { selection: { param: "document_id", id: "D" }, preview: { param: "preview", id: "V" } })
  assert.deepEqual(lanePart("?preview=V&type=all", groups), { selection: null, preview: { param: "preview", id: "V" } }, "a preview alone is no selection")
})

test("withLaneState sets the preview or takes it away and touches nothing else", () => {
  const current = new URL("http://x.test/k?type=all&document_id=D&search=x")
  const opened = withLaneState(current, { set: { preview: "V" } })
  assert.equal(opened.searchParams.get("preview"), "V")
  assert.equal(opened.searchParams.get("document_id"), "D")
  assert.equal(opened.searchParams.get("search"), "x")
  const back = withLaneState(opened, { remove: ["preview"] })
  assert.equal(back.searchParams.has("preview"), false)
  assert.equal(back.searchParams.get("document_id"), "D")
  assert.equal(current.searchParams.has("preview"), false, "the current address is not changed in place")
})

test("a page turn keeps the lane part of the CURRENT address: the open object and its preview, read at navigation time", () => {
  const groups = parseLaneParams(JSON.stringify({ selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] }))
  const current = new URL("http://x.test/org/o1/projects/p1/knowledge?type=all&document_id=D&preview=V&viewport=desktop")
  const turned = new URL(withLanePartOf("/org/o1/projects/p1/knowledge?type=all&page=2&note_id=OLD", { current, groups }))
  assert.equal(turned.searchParams.get("page"), "2")
  assert.equal(turned.searchParams.get("document_id"), "D")
  assert.equal(turned.searchParams.get("preview"), "V")
  assert.equal(turned.searchParams.has("note_id"), false, "a stale selection in the rendered href goes")
  assert.equal(turned.searchParams.has("viewport"), false, "a page-mode parameter is not lane state")
  const closed = new URL(withLanePartOf("/org/o1/projects/p1/knowledge?page=2&document_id=D", { current: new URL("http://x.test/k?type=all"), groups }))
  assert.equal(closed.searchParams.has("document_id"), false, "a closed lane clears the rendered selection")
})
