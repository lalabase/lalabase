// What: the three addresses of a list page with a lane (page, detail, way
//   back) and the pagination links, as list_row_controller writes them.
// Type: node:test unit spec over URLs; no browser, no DOM.
// Why: the address is the truth of the lane. Note A then document B must
//   leave ONE selection parameter, a click must keep search, view, conditions
//   and page, and a resource path with its own query must not get a second
//   "?" (doc/wissen_als_bahn_plan.md, S2, and the review's findings 1 and 2).
import { test } from "node:test"
import assert from "node:assert/strict"
import {
  openSelection, isOpen, canonicalAddress, withoutSelection, detailAddress
} from "../../../../app/javascript/lib/list_row/address.js"

const ORIGIN = "http://lalabase.test"
const INDEX = "/org/o1/projects/p1/knowledge"
const PARAMS = ["note_id", "document_id"]
const at = (path) => new URL(path, ORIGIN)

test("openSelection names the parameter the address carries, in the page's order", () => {
  assert.deepEqual(openSelection("?type=all&note_id=A", PARAMS), { param: "note_id", id: "A" })
  assert.deepEqual(openSelection("?document_id=B", PARAMS), { param: "document_id", id: "B" })
  assert.equal(openSelection("?type=all", PARAMS), null)
  assert.equal(openSelection(new URLSearchParams("?note_id="), PARAMS), null)
})

test("isOpen reads its own parameter only", () => {
  assert.equal(isOpen("?note_id=A", "note_id", "A"), true)
  assert.equal(isOpen("?note_id=A", "note_id", "B"), false)
  assert.equal(isOpen("?document_id=A", "note_id", "A"), false)
})

test("the page address keeps the live query and carries exactly one selection", () => {
  const current = at(`${INDEX}?type=all&search=x&filter%5Btag%5D=a&page=2&note_id=A`)
  const address = canonicalAddress({ current, indexUrl: INDEX, param: "document_id", params: PARAMS, id: "B" })

  assert.equal(address.pathname, INDEX)
  assert.equal(address.searchParams.get("document_id"), "B")
  assert.equal(address.searchParams.has("note_id"), false)
  assert.equal(address.searchParams.get("search"), "x")
  assert.equal(address.searchParams.get("filter[tag]"), "a")
  assert.equal(address.searchParams.get("page"), "2")
  assert.equal(address.searchParams.get("type"), "all")
})

test("a page without an index address keeps its current path", () => {
  const current = at("/org/o1/projects/p1/tickets?sort%5Bcolumn%5D=number")
  const address = canonicalAddress({ current, indexUrl: null, param: "ticket_id", params: ["ticket_id"], id: "T" })
  assert.equal(address.pathname, "/org/o1/projects/p1/tickets")
  assert.equal(address.searchParams.get("ticket_id"), "T")
  assert.equal(address.searchParams.get("sort[column]"), "number")
})

test("the way back drops every selection and nothing else", () => {
  const back = withoutSelection(at(`${INDEX}?type=note&search=x&note_id=A&document_id=B`), PARAMS)
  assert.equal(back.searchParams.has("note_id"), false)
  assert.equal(back.searchParams.has("document_id"), false)
  assert.equal(back.searchParams.get("search"), "x")
  assert.equal(back.searchParams.get("type"), "note")
})

test("the detail address is the resource with frame=content, the lane's frame and the live query", () => {
  const current = at(`${INDEX}?type=all&search=x&note_id=A&format=html&frame=content&frame_id=old`)
  const detail = new URL(detailAddress({ url: "/org/o1/projects/p1/notes/A", current, frame: "knowledge_display_frame", params: PARAMS }))

  assert.equal(detail.pathname, "/org/o1/projects/p1/notes/A")
  assert.equal(detail.searchParams.get("frame"), "content")
  assert.equal(detail.searchParams.get("frame_id"), "knowledge_display_frame")
  assert.equal(detail.searchParams.get("search"), "x")
  assert.equal(detail.searchParams.get("type"), "all")
  assert.equal(detail.searchParams.has("note_id"), false)
  assert.equal(detail.searchParams.has("format"), false)
})

test("a resource path with its own query gets no second question mark", () => {
  const current = at(`${INDEX}?type=all`)
  const detail = detailAddress({ url: "/org/o1/projects/p1/tickets/T?smart_folder_id=S", current, frame: "ticket_display_frame", params: ["ticket_id"] })
  assert.equal((detail.match(/\?/g) || []).length, 1)
  assert.equal(new URL(detail).searchParams.get("smart_folder_id"), "S")
  assert.equal(new URL(detail).searchParams.get("frame"), "content")
})

// The review of doc/dateivorschau_plan.md reproduced the loss: two values of
// filter[tag][] became one.
test("the detail address carries a repeated parameter whole", () => {
  const current = at(`${INDEX}?filter%5Btag%5D%5B%5D=a&filter%5Btag%5D%5B%5D=b&document_id=D`)
  const detail = new URL(detailAddress({ url: "/org/o1/projects/p1/documents/D", current, frame: "f", params: PARAMS }))
  assert.deepEqual(detail.searchParams.getAll("filter[tag][]"), ["a", "b"])
  assert.equal(detail.searchParams.has("document_id"), false)
})
