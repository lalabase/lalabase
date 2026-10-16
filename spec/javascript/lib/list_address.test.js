// What: the address of "Alle Meetings" after its list frame loaded (lib/list_address.js).
// Why:  the filter bar reads sort and the open view from window.location. A
//   column head or a page link reloads only the frame; an address that stayed
//   behind lost the sort on the next filter and the page on a reload (review
//   of the overview filter bar, P2).
import { test } from "node:test"
import assert from "node:assert/strict"
import { listAddress } from "../../../app/javascript/lib/list_address.js"

const PATH = "/org/o1/meetings"

test("the address is the path with the state the frame rendered", () => {
  const rendered = "filter%5Bproject%5D%5B%5D=p1&page=2&sort%5Bcolumn%5D=title&sort%5Bdirection%5D=asc"
  const params = new URL(listAddress(PATH, rendered), "http://x.invalid").searchParams

  assert.deepEqual(params.getAll("filter[project][]"), ["p1"])
  assert.equal(params.get("sort[column]"), "title")
  assert.equal(params.get("sort[direction]"), "asc")
  assert.equal(params.get("page"), "2")
})

test("a state that no longer has a condition takes it out of the address", () => {
  assert.equal(listAddress(PATH, "search=Kickoff"), `${PATH}?search=Kickoff`)
  assert.equal(listAddress(PATH, ""), PATH)
})

test("page 1 is no page", () => {
  assert.equal(listAddress(PATH, "page=1&smart_folder_id=v1"), `${PATH}?smart_folder_id=v1`)
})

test("a frame without a rendered state leaves the address alone", () => {
  assert.equal(listAddress(PATH, undefined), null)
  assert.equal(listAddress(PATH, null), null)
  assert.equal(listAddress("", "search=x"), null)
})
