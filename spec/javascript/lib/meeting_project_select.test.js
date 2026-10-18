// What: chosenFormUrl (lib/meeting_project_select.js), which form the frame
//   below the project select of "Alle Meetings" shows.
// Type: node:test, pure function over a select-shaped object.
// Why: "nothing chosen" decides twice (a changed choice, a late answer), so
//   every way of choosing nothing has to say null.
import { test } from "node:test"
import assert from "node:assert/strict"
import { chosenFormUrl } from "../../../app/javascript/lib/meeting_project_select.js"

const select = (option) => ({ selectedOptions: option ? [option] : [] })

test("the chosen option's address from ERB, as it stands", () => {
  const url = "/projects/p1/meetings/new?frame=content&frame_id=meeting_new_form&list_context=organisation"
  assert.equal(chosenFormUrl(select({ dataset: { formUrl: url } })), url)
})

test("the prompt, an option without an address and no select choose nothing", () => {
  assert.equal(chosenFormUrl(select({ dataset: {} })), null)
  assert.equal(chosenFormUrl(select({ dataset: { formUrl: "" } })), null)
  assert.equal(chosenFormUrl(select(null)), null)
  assert.equal(chosenFormUrl(null), null)
})
