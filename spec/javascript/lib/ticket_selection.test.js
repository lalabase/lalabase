// What: the selection model of the ticket list (doc/ticket_bulk_edit_plan.md, slice 1).
// Type: node:test unit spec, no browser.
// Why: the controller only renders this; the rules live here. A range that runs
//   the wrong way, a head box that ticks more than the page, or a selection
//   that survives a filter change would each be a wrong list under a right UI.
import { test } from "node:test"
import assert from "node:assert/strict"
import { TicketSelection, normalizeAddress } from "../../../app/javascript/lib/ticket_selection.js"

const page = ["a", "b", "c", "d", "e"]

test("a box ticks one row and becomes the anchor", () => {
  const selection = new TicketSelection()
  selection.set("b", true)
  assert.equal(selection.count, 1)
  assert.ok(selection.has("b"))
  assert.equal(selection.anchor, "b")
  selection.set("b", false)
  assert.equal(selection.count, 0)
})

test("shift-click takes the range between the anchor and the row, in either direction", () => {
  const selection = new TicketSelection()
  selection.set("b", true)
  selection.range("d", page, true)
  assert.deepEqual(selection.toArray().sort(), ["b", "c", "d"])

  selection.range("a", page, true)
  assert.deepEqual(selection.toArray().sort(), ["a", "b", "c", "d"])
  assert.equal(selection.anchor, "a")
})

test("a shift-click that unticks clears the range", () => {
  const selection = new TicketSelection()
  selection.setPage(page, true)
  selection.set("b", true)
  selection.range("d", page, false)
  assert.deepEqual(selection.toArray().sort(), ["a", "e"])
})

test("a shift-click without an anchor on this page is a plain tick", () => {
  const selection = new TicketSelection()
  selection.range("c", page, true)
  assert.deepEqual(selection.toArray(), ["c"])

  selection.anchor = "gone"
  selection.range("e", page, true)
  assert.deepEqual(selection.toArray().sort(), ["c", "e"])
})

test("the head box takes the loaded page and nothing more", () => {
  const selection = new TicketSelection()
  selection.set("other-page", true)
  selection.setPage(page, true)
  assert.equal(selection.count, 6)
  assert.equal(selection.pageState(page), "all")

  selection.setPage(page, false)
  assert.deepEqual(selection.toArray(), ["other-page"])
  assert.equal(selection.pageState(page), "none")
})

test("the head box state is none, some or all of the loaded page", () => {
  const selection = new TicketSelection()
  assert.equal(selection.pageState(page), "none")
  assert.equal(selection.pageState([]), "none")
  selection.set("a", true)
  assert.equal(selection.pageState(page), "some")
  selection.setPage(page, true)
  assert.equal(selection.pageState(page), "all")
})

test("the same address keeps the selection, a different one drops it and says so", () => {
  const selection = new TicketSelection({ address: "filter[tag][]=bug" })
  selection.set("a", true)

  assert.equal(selection.reconcile("filter[tag][]=bug"), false)
  assert.equal(selection.count, 1)

  assert.equal(selection.reconcile("filter[tag][]=ui"), true)
  assert.equal(selection.count, 0)
  assert.equal(selection.anchor, null)
  assert.equal(selection.address, "filter[tag][]=ui")

  assert.equal(selection.reconcile("search=x"), false, "nothing to drop reports nothing")
})

test("the address ignores the page, the page size and the opened ticket, and orders itself", () => {
  assert.equal(normalizeAddress("?page=3&filter[tag][]=bug&ticket_id=t1&items=50"), "filter%5Btag%5D%5B%5D=bug")
  assert.equal(normalizeAddress("?b=2&a=1"), normalizeAddress("?a=1&b=2"))
  assert.equal(normalizeAddress(""), "")
  assert.notEqual(normalizeAddress("?smart_folder_id=1"), normalizeAddress("?smart_folder_id=2"))
})

test("encoded delimiters cannot collide with separate address parameters", () => {
  assert.notEqual(
    normalizeAddress("?search=foo%26sort%5Bcolumn%5D%3Dtitle"),
    normalizeAddress("?search=foo&sort[column]=title")
  )
})

// Slice 2: the second step to every hit of the address.

test("all is offered only once the loaded page is fully ticked and there is more", () => {
  const selection = new TicketSelection()
  assert.equal(selection.canOfferAll(page, 214), false)
  selection.setPage(page, true)
  assert.equal(selection.canOfferAll(page, 214), true)
  assert.equal(selection.canOfferAll(page, 5), false, "the page IS everything")
  assert.equal(selection.canOfferAll(page, 4), false, "fewer hits than rows never offers")
  selection.set("c", false)
  assert.equal(selection.canOfferAll(page, 214), false)
})

test("all counts every hit and implies every loaded row", () => {
  const selection = new TicketSelection()
  selection.setPage(page, true)
  selection.selectAll(214)
  assert.equal(selection.isAll(), true)
  assert.equal(selection.count, 214)
  assert.equal(selection.isEmpty(), false)
  assert.equal(selection.has("not-loaded"), true)
  assert.equal(selection.pageState(page), "all")
  assert.equal(selection.canOfferAll(page, 214), false, "already all")
})

test("an untick while all stands drops back to the loaded page minus that row", () => {
  const selection = new TicketSelection()
  selection.selectAll(214)
  selection.set("c", false, page)
  assert.equal(selection.isAll(), false)
  assert.deepEqual(selection.toArray().sort(), ["a", "b", "d", "e"])
  assert.equal(selection.count, 4)
})

test("a tick while all stands changes nothing, the head box unticked ends all", () => {
  const selection = new TicketSelection()
  selection.selectAll(214)
  selection.set("a", true, page)
  assert.equal(selection.isAll(), true)
  selection.setPage(page, false)
  assert.equal(selection.isAll(), false)
  assert.equal(selection.count, 0)
})

test("a shift-untick while all stands drops to the page and clears the range", () => {
  const selection = new TicketSelection()
  selection.selectAll(214)
  selection.anchor = "b"
  selection.range("d", page, false)
  assert.equal(selection.isAll(), false)
  assert.deepEqual(selection.toArray().sort(), ["a", "e"])
})

test("all lapses with the address like the ticks do, and clear ends it", () => {
  const selection = new TicketSelection({ address: "" })
  selection.selectAll(214)
  assert.equal(selection.reconcile("search=x"), true)
  assert.equal(selection.isAll(), false)
  assert.equal(selection.count, 0)

  selection.selectAll(3)
  selection.clear()
  assert.equal(selection.isAll(), false)
  assert.equal(selection.isEmpty(), true)
})

test("viewport changes preserve a selection, while a real filter change clears it", () => {
  const initial = normalizeAddress("?search=foo")
  const selection = new TicketSelection({ address: initial })
  selection.set("a", true)
  assert.equal(normalizeAddress("?search=foo&viewport=mobile&page=2"), initial)
  assert.notEqual(normalizeAddress("?search=bar&viewport=mobile&page=2"), initial)
})
