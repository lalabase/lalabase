// What: lane_link_controller, the link that moves the lane to a state of the
//   open object (D2 of doc/dateivorschau_plan.md): the file name opens the
//   preview, the head's way back returns to the document.
// Type: node:test over the controller's source in a vm context, the way
//   list_row_controller.test.js does it.
// Why: both addresses come from the address bar at click time, never from a
//   rendered href, so a filter changed after the render is not written back;
//   below 1024 px the page is visited; the entry is the page's own.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import * as address from "../../../app/javascript/lib/list_row/address.js"
import * as params from "../../../app/javascript/lib/lane/params.js"

const source = readFileSync(new URL("../../../app/javascript/controllers/lane_link_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class LaneLinkController")

const GROUPS = JSON.stringify({ selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] })
const ORIGIN = "http://lalabase.test"
const INDEX = "/org/o1/projects/p1/knowledge"

function fixture({ href, innerWidth = 1400, values }) {
  const log = { history: [], frameSrc: null, location: null, listeners: [], unmarked: [] }
  const markedRow = { classList: { remove: (...names) => log.unmarked.push(...names) } }
  const location = new URL(href, ORIGIN)
  const window = {
    innerWidth,
    location: {
      get href() { return location.href },
      set href(value) { log.location = value }
    },
    history: { pushState: (state, title, url) => { log.history.push([state, url]); location.href = url } }
  }
  const frame = { setAttribute: (name, value) => { if (name === "src") log.frameSrc = value }, querySelector: () => null }
  const document = {
    getElementById: (id) => (id === values.frame ? frame : null),
    querySelectorAll: (selector) => (selector === ".selected-row" ? [markedRow] : []),
    addEventListener: (name, fn) => log.listeners.push(name),
    removeEventListener: () => {}
  }
  const Controller = runInNewContext(`${source}\nLaneLinkController`, { Controller: class {}, ...address, ...params, window, document, URL, URLSearchParams })
  const controller = new Controller()
  controller.element = { closest: (selector) => (selector === "[data-lane-params]" ? { dataset: { laneParams: GROUPS } } : null) }
  for (const [key, value] of Object.entries(values)) controller[`${key}Value`] = value
  const click = (modifiers = {}) => {
    const event = { preventDefault: () => { log.prevented = true }, button: 0, ...modifiers }
    controller.click(event)
  }
  return { click, log, location }
}

const open = { url: "/org/o1/projects/p1/documents/D/preview?version_id=V", frame: "knowledge_display_frame", set: { preview: "V" }, remove: [], focus: "" }
const back = { url: "/org/o1/projects/p1/documents/D", frame: "knowledge_display_frame", set: {}, remove: ["preview"], focus: "[data-preview-link-for='V']" }

test("opening the preview writes it into the CURRENT address and loads the frame with the live query", () => {
  const { click, log, location } = fixture({ href: `${INDEX}?type=all&search=y&document_id=D`, values: open })
  click()
  assert.equal(location.searchParams.get("preview"), "V")
  assert.equal(location.searchParams.get("document_id"), "D")
  assert.equal(location.searchParams.get("search"), "y")
  // The state object is born in the vm context: compare its fields, not its prototype.
  assert.equal(log.history[0][0].lane, true)
  const frame = new URL(log.frameSrc)
  assert.equal(frame.pathname, "/org/o1/projects/p1/documents/D/preview")
  assert.equal(frame.searchParams.get("version_id"), "V")
  assert.equal(frame.searchParams.get("search"), "y")
  assert.equal(frame.searchParams.has("preview"), false)
  assert.equal(frame.searchParams.has("document_id"), false)
})

test("the way back takes the preview out of the address, loads the document and arranges the focus", () => {
  const { click, log, location } = fixture({ href: `${INDEX}?type=all&document_id=D&preview=V`, values: back })
  click()
  assert.equal(location.searchParams.has("preview"), false)
  assert.equal(location.searchParams.get("document_id"), "D")
  assert.equal(new URL(log.frameSrc).pathname, "/org/o1/projects/p1/documents/D")
  assert.deepEqual(log.listeners, ["turbo:frame-load"])
})

test("below 1024px the link visits the page address and touches no frame", () => {
  const { click, log } = fixture({ href: `${INDEX}?type=all&document_id=D`, innerWidth: 900, values: open })
  click()
  assert.equal(new URL(log.location, ORIGIN).searchParams.get("preview"), "V")
  assert.equal(log.frameSrc, null)
  assert.deepEqual(log.history, [])
})

test("a modified click (a new tab, a new window) is the browser's: nothing is prevented, pushed or loaded", () => {
  for (const modifiers of [{ metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
    const { click, log, location } = fixture({ href: `${INDEX}?type=all&document_id=D`, values: open })
    click(modifiers)
    assert.equal(log.prevented, undefined, JSON.stringify(modifiers))
    assert.deepEqual(log.history, [])
    assert.equal(log.frameSrc, null)
    assert.equal(location.searchParams.has("preview"), false)
  }
})

// The "+" of "Alle Meetings" takes meeting_id out of the address and loads the
// project select: no row is open any more, so none may stay marked (the full
// visit of that address marks none either).
test("a link that takes the selection out of the address clears the mark of the open row", () => {
  const plus = { url: INDEX, frame: "knowledge_display_frame", set: { new: "note" }, remove: ["document_id"], focus: "" }
  const { click, log, location } = fixture({ href: `${INDEX}?document_id=D`, values: plus })
  click()
  assert.equal(location.searchParams.get("document_id"), null)
  assert.deepEqual(log.unmarked, ["selected-row"])
})

test("a link that keeps the selection keeps the mark of the open row", () => {
  const { click, log } = fixture({ href: `${INDEX}?document_id=D&preview=V`, values: back })
  click()
  assert.deepEqual(log.unmarked, [])
})
