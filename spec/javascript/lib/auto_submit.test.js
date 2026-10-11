// What: which control makes an auto-submit form send itself (lib/auto_submit.js).
// Why:  the one decision that used to be three ifs in the controller, pinned
//   where node:test can reach it. The case that made it a lib: an input
//   without a name, the billing picker's filter box, armed a debounced submit
//   whose late frame answer cancelled the page visit a billing choice makes.
import { test } from "node:test"
import assert from "node:assert/strict"
import { submitTrigger } from "../../../app/javascript/lib/auto_submit.js"

test("a select, checkbox, date or hidden input submits at once", () => {
  for (const type of ["select-one", "checkbox", "radio", "date", "hidden", undefined]) {
    assert.equal(submitTrigger({ name: "project_id_filter", type }), "now", `type ${type}`)
  }
})

test("typing is debounced", () => {
  assert.equal(submitTrigger({ name: "search", type: "text" }), "debounced")
  assert.equal(submitTrigger({ name: "search", type: "search" }), "debounced")
})

test("a submit or button control is not a filter", () => {
  assert.equal(submitTrigger({ name: "commit", type: "submit" }), null)
  assert.equal(submitTrigger({ name: "x", type: "button" }), null)
})

// THE case: a control without a name cannot change what the form sends, so it
// never submits it, however it is typed.
test("a control without a name never submits, whatever its type", () => {
  assert.equal(submitTrigger({ name: "", type: "text" }), null)
  assert.equal(submitTrigger({ type: "text" }), null)
  assert.equal(submitTrigger({ name: "", type: "select-one" }), null)
  assert.equal(submitTrigger(null), null)
})

// A pair of controls that only means something together opts out, and its own
// button does the submitting. Without this the custom period applied "from" the
// moment it was typed, against a "to" the reader had not touched yet.
test("a control marked auto-submit-skip never submits, whatever its type", () => {
  assert.equal(submitTrigger({ name: "start_date", type: "date", dataset: { autoSubmitSkip: "" } }), null)
  assert.equal(submitTrigger({ name: "search", type: "text", dataset: { autoSubmitSkip: "" } }), null)
})

// n-1: the same field WITHOUT the mark still submits at once, or the opt-out
// would be indistinguishable from date inputs having been blacklisted wholesale.
test("a date field without the mark still submits at once", () => {
  assert.equal(submitTrigger({ name: "start_date", type: "date", dataset: {} }), "now")
})
