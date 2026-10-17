// What: which controls of a list page with a lane take the list state when the
//   list changes beside an open lane (lib/lane/filter_context.js).
// Type: node:test unit spec over paths; no browser.
// Why: "Alle Meetings" shows a project's meeting in its lane. Its edit, delete
//   and search switch live below that project's meetings index, so a rule that
//   knew only the page's own index left them with the state the list had when
//   the lane was opened: a save redrew the list with old filters. A control of
//   another list (a linked ticket) must stay as it is.
import { test } from "node:test"
import assert from "node:assert/strict"
import { controlIndexPath, indexPaths } from "../../../../app/javascript/lib/lane/filter_context.js"

const ORIGIN = "http://x.test"
const OVERVIEW = "/org/o1/meetings"
const PROJECT = "/org/o1/projects/p1/meetings"

test("the page's own index and what lies below it", () => {
  assert.equal(controlIndexPath(PROJECT, [PROJECT]), PROJECT)
  assert.equal(controlIndexPath(`${PROJECT}/m1/edit.turbo_stream`, [PROJECT]), PROJECT)
  assert.equal(controlIndexPath(`${PROJECT}/m1.turbo_stream`, [PROJECT]), PROJECT)
})

test("on the overview, the lane's controls belong to the index its head names", () => {
  const paths = indexPaths(OVERVIEW, [PROJECT], ORIGIN)
  assert.deepEqual(paths, [OVERVIEW, PROJECT])
  assert.equal(controlIndexPath(`${PROJECT}/m1/toggle_search`, paths), PROJECT)
  assert.equal(controlIndexPath(`${OVERVIEW}`, paths), OVERVIEW)
})

test("without a lane head only the page's index counts (tickets, knowledge)", () => {
  const paths = indexPaths(OVERVIEW, [], ORIGIN)
  assert.equal(controlIndexPath(`${PROJECT}/m1/toggle_search`, paths), null)
})

test("a control of another list or a path that only starts alike is left alone", () => {
  const paths = indexPaths(OVERVIEW, [PROJECT], ORIGIN)
  assert.equal(controlIndexPath("/org/o1/projects/p1/tickets/t1", paths), null)
  assert.equal(controlIndexPath("/org/o1/projects/p1/meetings_archive", paths), null)
  assert.equal(controlIndexPath("/org/o1/meetingsx", paths), null)
})

test("the same index twice is one, and full addresses become paths", () => {
  assert.deepEqual(indexPaths(`${ORIGIN}${PROJECT}?search=x`, [PROJECT, null], ORIGIN), [PROJECT])
})
