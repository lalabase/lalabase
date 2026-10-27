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
import { controlIndexPath, indexPaths, withLiveLane } from "../../../../app/javascript/lib/lane/filter_context.js"

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

// Review of PR #51: a sort head is a list link, rendered with the selection
// of the page request. A row click changes the open person in the address
// only, so at click time the link takes the lane part of the live address:
// the person open now, or none when the lane was closed.
test("a link that keeps the lane takes the live selection, not the rendered one", () => {
  const names = ["person_id", "member_id"]
  const link = new URL(`${ORIGIN}/org/o1/people?sort=last&person_id=a`)

  const switched = withLiveLane(link, new URL(`${ORIGIN}/org/o1/people?person_id=b`), names)
  assert.equal(switched.search, "?sort=last&person_id=b")

  const member = withLiveLane(link, new URL(`${ORIGIN}/org/o1/people?member_id=m`), names)
  assert.equal(member.search, "?sort=last&member_id=m")

  const closed = withLiveLane(link, new URL(`${ORIGIN}/org/o1/people`), names)
  assert.equal(closed.search, "?sort=last")

  assert.equal(link.search, "?sort=last&person_id=a", "the rendered address is not changed in place")
})
