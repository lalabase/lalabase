// What: the two decisions of the org-wide "new meeting" modal (lib/meeting_modal.js).
// Why:  both were review findings on PR #716 that no server-side spec can see, and
//   spec/system does not run in CI while this file does (guards.yml -> npm test).
//
//   newFormUrl: the modal lives OUTSIDE the results frame, and the filter bar
//   reloads only that frame, so the page never re-renders and anything ERB put into
//   every data-new-url is frozen at first load. The list frame writes its state at
//   every load (data-list-filter-query); the modal adds exactly that.
//
//   submissionClosesModal: Turbo's detail.success is response.ok AFTER fetch
//   followed redirects. The area gate answers a denied write with redirect_to, so a
//   modal closing on detail.success closed on a save that never happened, throwing
//   away a pasted transcript and showing no reason.
import { test } from "node:test"
import assert from "node:assert/strict"
import { newFormUrl, submissionClosesModal, responseContentType } from "../../../app/javascript/lib/meeting_modal.js"

const BASE = "/organisations/o1/projects/p1/meetings/new?frame=modal"

const LIST = "search=Kickoff&filter%5Bproject%5D%5B%5D=p9&filter%5Bparticipant%5D%5B%5D=anna+mueller&filter_op%5Bparticipant%5D=and&smart_folder_id=v1"

test("adds the list state as it stands, the project condition as filter[project][]", () => {
  const params = new URL(newFormUrl(BASE, LIST), "http://x.invalid").searchParams

  assert.equal(params.get("search"), "Kickoff")
  assert.deepEqual(params.getAll("filter[project][]"), ["p9"])
  assert.deepEqual(params.getAll("filter[participant][]"), ["anna mueller"])
  assert.equal(params.get("filter_op[participant]"), "and")
  assert.equal(params.get("smart_folder_id"), "v1")
  // project_id is the nested route's OWN parameter; the list never names it.
  assert.equal(params.get("project_id"), null)
})

test("keeps several values of one condition", () => {
  const params = new URL(newFormUrl(BASE, "filter%5Bproject%5D%5B%5D=p1&filter%5Bproject%5D%5B%5D=p2"), "http://x.invalid").searchParams

  assert.deepEqual(params.getAll("filter[project][]"), ["p1", "p2"])
})

test("keeps the frame marker and the path untouched, even against the list state", () => {
  const url = newFormUrl(BASE, "frame=other&search=Kickoff")

  assert.equal(url.split("?")[0], "/organisations/o1/projects/p1/meetings/new")
  assert.deepEqual(new URL(url, "http://x.invalid").searchParams.getAll("frame"), ["modal"])
})

test("no option selected means no URL, so the frame falls back to its zero state", () => {
  assert.equal(newFormUrl(undefined, LIST), null)
  assert.equal(newFormUrl("", ""), null)
})

test("an empty list state leaves the base URL alone", () => {
  assert.equal(newFormUrl(BASE), BASE)
  assert.equal(newFormUrl(BASE, ""), BASE)
  assert.equal(newFormUrl(BASE, null), BASE)
})

const turboStream = (ok) => ({
  success: ok,
  fetchResponse: { header: (n) => (n === "Content-Type" ? "text/vnd.turbo-stream.html; charset=utf-8" : null) }
})

test("closes only on a turbo-stream answer, which is the only proof of a save", () => {
  assert.equal(submissionClosesModal(turboStream(true)), true)
})

test("does NOT close on a redirect that fetch followed to a 200 HTML page", () => {
  // A revoked write, a deleted project or an expired session: ProjectController
  // answers redirect_to, fetch follows it, response.ok is true. Closing here loses
  // everything the reader typed and says nothing.
  const redirected = {
    success: true,
    fetchResponse: { header: () => "text/html; charset=utf-8" }
  }
  assert.equal(submissionClosesModal(redirected), false)
})

test("does NOT close on a validation error, so the messages stay visible", () => {
  assert.equal(submissionClosesModal(turboStream(false)), false)
})

test("does NOT close when the response shape is unknown", () => {
  // Fail closed: an unreadable answer must leave the reader's work on screen.
  assert.equal(submissionClosesModal(undefined), false)
  assert.equal(submissionClosesModal({ success: true }), false)
  assert.equal(submissionClosesModal({ success: true, fetchResponse: {} }), false)
})

test("reads the content type from the raw Response when Turbo's accessor is gone", () => {
  const raw = { response: { headers: { get: () => "text/vnd.turbo-stream.html" } } }
  assert.equal(responseContentType(raw), "text/vnd.turbo-stream.html")
  assert.equal(submissionClosesModal({ success: true, fetchResponse: raw }), true)
})
