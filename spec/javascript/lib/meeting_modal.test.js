// What: the two decisions of the org-wide "new meeting" modal (lib/meeting_modal.js).
// Why:  both were review findings on PR #716 that no server-side spec can see, and
//   spec/system does not run in CI while this file does (guards.yml -> npm test).
//
//   newFormUrl: the modal lives OUTSIDE the results frame, and the filter row is a
//   frame-scoped GET without history advance, so the page never re-renders and the
//   filter values ERB put into every data-new-url are frozen at first load. Saving
//   then refreshed the list with values the filter controls no longer showed.
//
//   submissionClosesModal: Turbo's detail.success is response.ok AFTER fetch
//   followed redirects. The area gate answers a denied write with redirect_to, so a
//   modal closing on detail.success closed on a save that never happened, throwing
//   away a pasted transcript and showing no reason.
import { test } from "node:test"
import assert from "node:assert/strict"
import { newFormUrl, submissionClosesModal, responseContentType } from "../../../app/javascript/lib/meeting_modal.js"

const BASE = "/organisations/o1/projects/p1/meetings/new?frame=modal"

test("merges the live filter values in, renaming project_id for the nested route", () => {
  const url = newFormUrl(BASE, { search: "Kickoff", participant: "anna mueller", projectId: "p9" })
  const params = new URL(url, "http://x.invalid").searchParams

  assert.equal(params.get("search"), "Kickoff")
  assert.equal(params.get("participant"), "anna mueller")
  // project_id is the nested route's OWN parameter, so the overview filter must
  // arrive under a different name or it would silently retarget the route.
  assert.equal(params.get("overview_project_id"), "p9")
  assert.equal(params.get("project_id"), null)
})

test("keeps the frame marker and the path untouched", () => {
  const url = newFormUrl(BASE, { search: "Kickoff" })

  assert.equal(url.split("?")[0], "/organisations/o1/projects/p1/meetings/new")
  assert.equal(new URL(url, "http://x.invalid").searchParams.get("frame"), "modal")
})

test("a cleared filter REMOVES the value ERB baked in at page load", () => {
  // The exact regression: the page was opened with ?participant=Anna, the reader
  // then cleared the select. Keeping the stale value would refresh the list
  // filtered to Anna and hide the meeting that was just saved.
  const stale = `${BASE}&participant=Anna&search=old&overview_project_id=p9`

  for (const blank of [undefined, null, "", "   "]) {
    const params = new URL(newFormUrl(stale, { search: blank, participant: blank, projectId: blank }),
                           "http://x.invalid").searchParams
    assert.equal(params.get("participant"), null, `participant for ${JSON.stringify(blank)}`)
    assert.equal(params.get("search"), null)
    assert.equal(params.get("overview_project_id"), null)
    assert.equal(params.get("frame"), "modal")
  }
})

test("no option selected means no URL, so the frame falls back to its zero state", () => {
  assert.equal(newFormUrl(undefined, { search: "Kickoff" }), null)
  assert.equal(newFormUrl("", {}), null)
})

test("no filters at all leaves the base URL alone", () => {
  assert.equal(newFormUrl(BASE), BASE)
  assert.equal(newFormUrl(BASE, {}), BASE)
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
