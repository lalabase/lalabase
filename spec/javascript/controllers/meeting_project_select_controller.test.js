// What: meeting_project_select_controller, the project select of "Neues
//   Meeting" on "Alle Meetings" (meetings_overview/_new_meeting_lane).
// Type: node:test over the controller's source in a vm context, the way
//   lane_link_controller.test.js does it.
// Why: the choice loads its project's form into the frame below; taking it
//   back shows the zero state, also when an answer asked for before arrives
//   after (Turbo cancels a frame visit only for a new one).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import * as lib from "../../../app/javascript/lib/meeting_project_select.js"

const source = readFileSync(new URL("../../../app/javascript/controllers/meeting_project_select_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class MeetingProjectSelectController")

const URL_A = "/projects/A/meetings/new?frame=content&frame_id=meeting_new_form&list_context=organisation"
const URL_B = "/projects/B/meetings/new?frame=content&frame_id=meeting_new_form&list_context=organisation"
const PLACEHOLDER = { placeholder: true }

function fixture() {
  const listeners = {}
  const frame = {
    attributes: {},
    children: ["form of A"],
    setAttribute(name, value) { this.attributes[name] = value },
    removeAttribute(name) { delete this.attributes[name] },
    replaceChildren(...nodes) { this.children = nodes },
    addEventListener(name, fn) { listeners[name] = fn },
    removeEventListener(name) { delete listeners[name] }
  }
  const options = { "": { dataset: {} }, A: { dataset: { formUrl: URL_A } }, B: { dataset: { formUrl: URL_B } } }
  const select = { value: "", get selectedOptions() { return [options[this.value]] } }
  const placeholder = { content: { cloneNode: () => PLACEHOLDER } }
  const Controller = runInNewContext(`${source}\nMeetingProjectSelectController`, { Controller: class {}, ...lib })
  const controller = new Controller()
  Object.assign(controller, { selectTarget: select, frameTarget: frame, placeholderTarget: placeholder })
  controller.connect()
  return { controller, frame, select, listeners }
}

test("a choice loads the form of its project, a new choice the other one", () => {
  const { controller, frame, select } = fixture()
  select.value = "A"
  controller.choose()
  assert.equal(frame.attributes.src, URL_A)
  select.value = "B"
  controller.choose()
  assert.equal(frame.attributes.src, URL_B)
})

// The answer for B can be a redirect (the right went, the project was deleted, the
// session expired): frame-error then only puts its message on top, and the form of A
// stayed under the name B, ready to save into A.
test("a new choice takes the form of the project chosen before away at once", () => {
  const { controller, frame, select } = fixture()
  select.value = "A"
  controller.choose()
  frame.children = ["form of A"]
  select.value = "B"
  controller.choose()
  assert.equal(frame.attributes.src, URL_B)
  assert.deepEqual(frame.children, [])
})

test("taking the choice back shows the zero state and asks for nothing", () => {
  const { controller, frame, select } = fixture()
  select.value = "A"
  controller.choose()
  select.value = ""
  controller.choose()
  assert.equal(frame.attributes.src, undefined)
  assert.deepEqual(frame.children, [PLACEHOLDER])
})

test("an answer that arrives after the choice was taken back is put back to the zero state", () => {
  const { frame, select, listeners } = fixture()
  frame.attributes.src = URL_A
  select.value = ""
  frame.children = ["late form of A"]
  listeners["turbo:frame-load"]()
  assert.deepEqual(frame.children, [PLACEHOLDER])
  assert.equal(frame.attributes.src, undefined)
})

test("an answer for the chosen project stays", () => {
  const { frame, select, listeners } = fixture()
  select.value = "A"
  frame.attributes.src = URL_A
  frame.children = ["form of A"]
  listeners["turbo:frame-load"]()
  assert.deepEqual(frame.children, ["form of A"])
})

test("disconnect lets go of the frame", () => {
  const { controller, listeners } = fixture()
  controller.disconnect()
  assert.equal(listeners["turbo:frame-load"], undefined)
})
