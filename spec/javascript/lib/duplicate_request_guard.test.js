// What: which Turbo requests the duplicate guard of application.js may hold back
//   (lib/duplicate_request_guard.js).
// Why:  it held back every request repeated inside 500 ms, a GET as well. Turbo cancels the GET
//   that a new one replaces, so the guard stopped the only one left: a double click on the "+"
//   of the ticket list opened nothing (lalabase/lalabase#262). The browser side is
//   spec/system/turbo_double_click_spec.rb.
import { test } from "node:test"
import assert from "node:assert/strict"
import { duplicateRequestKey } from "../../../app/javascript/lib/duplicate_request_guard.js"

const form = "https://lalabase.test/org/o/projects/p/tickets/new?source=index_page"
const list = "https://lalabase.test/org/o/projects/p/tickets"

test("a GET is never held back: into a frame, for a page, or without a method", () => {
  assert.equal(duplicateRequestKey(form, "GET", "writing_surface"), null)
  assert.equal(duplicateRequestKey(list, "get", ""), null)
  assert.equal(duplicateRequestKey(list, undefined, undefined), null)
})

test("a write to a guarded list is keyed by method, target frame and address", () => {
  assert.equal(duplicateRequestKey(list, "post", "writing_surface"), `POST writing_surface ${list}`)
  assert.equal(duplicateRequestKey(list, "PATCH", undefined), `PATCH  ${list}`)
})

test("the same write into another frame, or with another method, is another request", () => {
  const key = duplicateRequestKey(list, "POST", "writing_surface")

  assert.notEqual(duplicateRequestKey(list, "POST", "tickets_list_frame"), key)
  assert.notEqual(duplicateRequestKey(list, "PATCH", "writing_surface"), key)
})

test("each list that saves from a form is guarded", () => {
  for (const path of ["/notes", "/tickets", "/documents", "/time_sessions"]) {
    assert.notEqual(duplicateRequestKey(`https://lalabase.test/org/o/projects/p${path}`, "POST", ""), null, path)
  }
})

test("a write anywhere else, or without an address, is not guarded", () => {
  assert.equal(duplicateRequestKey("https://lalabase.test/org/o/people", "POST", ""), null)
  assert.equal(duplicateRequestKey(null, "POST", ""), null)
})
