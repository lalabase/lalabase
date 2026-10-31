// What: the address and the timing of a list frame's reload (lib/list_frame_reload.js).
// Why:  the first version reloaded from the page's address and threw away sort and page, which
//   live only in the frame's src. And a second reload inside the 500 ms duplicate guard of
//   application.js was dropped unseen, so the row of the later write never reached the list.
import { test } from "node:test"
import assert from "node:assert/strict"
import { listFrameAddress, reloadWait, RELOAD_GAP_MS } from "../../../app/javascript/lib/list_frame_reload.js"

const live = "https://lalabase.test/org/o/projects/p/tickets?ticket_id=new&search=Filler"

test("without a frame source the live address is the whole answer", () => {
  assert.equal(listFrameAddress(live, null), live)
})

test("sort and page come from the frame, they are not in the address", () => {
  const source = "/org/o/projects/p/tickets?ticket_id=old&search=Filler&sort%5Bcolumn%5D=title&sort%5Bdirection%5D=asc&page=2"

  const address = new URL(listFrameAddress(live, source))

  assert.equal(address.searchParams.get("sort[column]"), "title")
  assert.equal(address.searchParams.get("sort[direction]"), "asc")
  assert.equal(address.searchParams.get("page"), "2")
})

test("filters and the open ticket stay those of the live address", () => {
  const source = "/org/o/projects/p/tickets?ticket_id=old&search=Stale&page=2"

  const address = new URL(listFrameAddress(live, source))

  assert.equal(address.searchParams.get("ticket_id"), "new")
  assert.equal(address.searchParams.get("search"), "Filler")
})

test("a frame back on page one drops a page the address still names", () => {
  const stale = `${live}&page=3&sort%5Bcolumn%5D=title`
  const source = "/org/o/projects/p/tickets?ticket_id=new&search=Filler"

  const address = new URL(listFrameAddress(stale, source))

  assert.equal(address.searchParams.has("page"), false)
  assert.equal(address.searchParams.has("sort[column]"), false)
})

test("the first reload does not wait", () => {
  assert.equal(reloadWait(undefined, 1000), 0)
})

test("a reload inside the gap waits for the rest of it", () => {
  assert.equal(reloadWait(1000, 1100), RELOAD_GAP_MS - 100)
})

test("a reload after the gap does not wait", () => {
  assert.equal(reloadWait(1000, 1000 + RELOAD_GAP_MS), 0)
})

test("the gap clears the 500 ms duplicate guard in application.js", () => {
  assert.ok(RELOAD_GAP_MS > 500)
})
