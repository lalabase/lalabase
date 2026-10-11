// What: the six steps of opening a row, as list_row_controller does them,
//   against fakes of the page (window, document, the layout toggle).
// Type: node:test over the controller's own source in a vm context, the way
//   column_picker_controller.test.js does it; the address rules themselves
//   live in lib/list_row/address.js and have their own spec.
// Why: the address is the truth of the lane (doc/wissen_als_bahn_plan.md,
//   S2). A first selection pushes and a second replaces, a click on the open
//   row closes, a narrow window goes to the page, a navigating row leaves,
//   and a row marks itself by PARAMETER and id on connect.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import * as address from "../../../app/javascript/lib/list_row/address.js"
import * as params from "../../../app/javascript/lib/lane/params.js"

const source = readFileSync(new URL("../../../app/javascript/controllers/list_row_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class ListRowController")

const INDEX = "/org/o1/projects/p1/knowledge"
const ORIGIN = "http://lalabase.test"

function fixture({ href, innerWidth = 1400, indexUrl = INDEX, rootHref = null, values }) {
  const log = { history: [], frameSrc: null, layout: [], location: null }
  const layoutToggle = {
    showContent: () => log.layout.push("show"),
    closeContent: () => log.layout.push("close")
  }
  const location = new URL(href, ORIGIN)
  const window = {
    innerWidth,
    location: {
      get href() { return location.href },
      set href(value) { log.location = value },
      get search() { return location.search },
      get pathname() { return location.pathname },
      get origin() { return location.origin }
    },
    history: {
      pushState: (state, title, url) => { log.history.push(["push", url]); location.href = url },
      replaceState: (state, title, url) => { log.history.push(["replace", url]); location.href = url }
    }
  }
  const frame = { setAttribute: (name, value) => { if (name === "src") log.frameSrc = value } }
  const document = {
    getElementById: (id) => (id === values.frame ? frame : null),
    querySelector: (selector) => (selector.includes("layout-toggle") ? {} : null),
    querySelectorAll: () => [],
    addEventListener: () => {},
    removeEventListener: () => {}
  }
  const Controller = runInNewContext(`${source}\nListRowController`, {
    Controller: class {}, ...address, ...params, window, document, console, URL, URLSearchParams
  })
  const controller = new Controller()
  const classes = new Set()
  // The page wrapper carries the parameter groups (D9 of
  // doc/dateivorschau_plan.md); the row's params value is the fallback.
  const groups = values.groups === undefined ? null : values.groups
  controller.element = {
    href: rootHref,
    matches: (selector) => selector === "a[href]" && Boolean(rootHref),
    classList: { toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)), remove: (name) => classes.delete(name) },
    closest: (selector) => {
      if (selector === "[data-index-url]" && indexUrl) return { dataset: { indexUrl } }
      if (selector === "[data-lane-params]" && groups) return { dataset: { laneParams: JSON.stringify(groups) } }
      return null
    }
  }
  controller.application = { getControllerForElementAndIdentifier: () => layoutToggle }
  for (const [key, value] of Object.entries(values)) controller[`${key}Value`] = value
  const click = (event = {}) => controller.click({
    button: 0,
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    target: { closest: () => null },
    preventDefault: () => {},
    ...event
  })
  return { controller, click, log, classes, location }
}

const KNOWLEDGE_PARAMS = ["note_id", "document_id"]
const KNOWLEDGE_GROUPS = { selection: KNOWLEDGE_PARAMS, preview: ["preview"], form: ["new"], ignore: ["viewport"] }
const noteA = { url: "/org/o1/projects/p1/notes/A", id: "A", param: "note_id", params: KNOWLEDGE_PARAMS, frame: "knowledge_display_frame", navigate: false }
const documentB = { ...noteA, url: "/org/o1/projects/p1/documents/B", id: "B", param: "document_id" }

test("the first selection pushes the page address with the live query; the second replaces it and leaves ONE parameter", () => {
  const { click, log, location } = fixture({ href: `${INDEX}?type=all&search=x`, values: noteA })
  click()
  assert.equal(log.history[0][0], "push")
  assert.equal(location.searchParams.get("note_id"), "A")
  assert.equal(location.searchParams.get("search"), "x")
  assert.deepEqual(log.layout, ["show"])
  assert.equal(new URL(log.frameSrc).pathname, "/org/o1/projects/p1/notes/A")
  assert.equal(new URL(log.frameSrc).searchParams.get("frame_id"), "knowledge_display_frame")

  const second = fixture({ href: location.href, values: documentB })
  second.click()
  assert.equal(second.log.history[0][0], "replace")
  assert.equal(second.location.searchParams.get("document_id"), "B")
  assert.equal(second.location.searchParams.has("note_id"), false)
  assert.equal(second.location.searchParams.get("search"), "x")
})

test("a click on the open row closes the lane and touches neither the address nor the frame", () => {
  const { click, log } = fixture({ href: `${INDEX}?type=all&note_id=A`, values: noteA })
  click()
  assert.deepEqual(log.layout, ["close"])
  assert.deepEqual(log.history, [])
  assert.equal(log.frameSrc, null)
})

test("below 1024px the row goes to the page address with the live query, not to the resource", () => {
  const { click, log } = fixture({ href: `${INDEX}?type=note&search=x`, innerWidth: 900, values: noteA })
  click()
  const target = new URL(log.location)
  assert.equal(target.pathname, INDEX)
  assert.equal(target.searchParams.get("note_id"), "A")
  assert.equal(target.searchParams.get("search"), "x")
  assert.deepEqual(log.history, [])
})

test("an anchored activity row uses its href as the narrow and no-JS fallback", () => {
  const resource = `${ORIGIN}/org/o1/projects/p1/documents/B`
  const { click, log } = fixture({
    href: `${INDEX}?type=all`,
    innerWidth: 900,
    rootHref: resource,
    values: documentB
  })

  click()
  assert.equal(log.location, resource)
  assert.deepEqual(log.history, [])
  assert.equal(log.frameSrc, null)
})

test("modifier clicks on an anchored activity row retain native link behaviour", () => {
  const resource = `${ORIGIN}/org/o1/projects/p1/documents/B`
  const { click, controller, log } = fixture({ href: `${INDEX}?type=all`, rootHref: resource, values: documentB })

  click({ metaKey: true, target: { closest: () => controller.element } })
  assert.deepEqual(log.history, [])
  assert.equal(log.location, null)
  assert.equal(log.frameSrc, null)
})

test("a navigating row leaves for its own area and does nothing else", () => {
  const { click, log } = fixture({ href: `${INDEX}?type=all`, values: { ...noteA, url: "/org/o1/projects/p1/meetings/M", id: "M", param: "meeting_id", navigate: true } })
  click()
  assert.equal(log.location, "/org/o1/projects/p1/meetings/M")
  assert.deepEqual(log.history, [])
  assert.deepEqual(log.layout, [])
})

test("on connect a row marks itself by parameter AND id, and stands unmarked under another parameter", () => {
  const marked = fixture({ href: `${INDEX}?note_id=A`, values: noteA })
  marked.controller.connect()
  assert.equal(marked.classes.has("selected-row"), true)

  const otherParam = fixture({ href: `${INDEX}?document_id=A`, values: noteA })
  otherParam.classes.add("selected-row")
  otherParam.controller.connect()
  assert.equal(otherParam.classes.has("selected-row"), false)

  const noSelection = fixture({ href: `${INDEX}?type=all`, values: noteA })
  noSelection.classes.add("selected-row")
  noSelection.controller.connect()
  assert.equal(noSelection.classes.has("selected-row"), true, "without a selection in the address the server's mark stands")
})

test("a page without an index address keeps its path", () => {
  const { click, location } = fixture({ href: "/org/o1/projects/p1/tickets?sort%5Bcolumn%5D=number", indexUrl: null, values: { url: "/org/o1/projects/p1/tickets/T", id: "T", param: "ticket_id", params: ["ticket_id"], frame: "ticket_display_frame", navigate: false } })
  click()
  assert.equal(location.pathname, "/org/o1/projects/p1/tickets")
  assert.equal(location.searchParams.get("ticket_id"), "T")
  assert.equal(location.searchParams.get("sort[column]"), "number")
})

// D9 of doc/dateivorschau_plan.md: with the page's groups a row click clears
// the open object's preview too, and the entry is the page's own.
test("with the page's groups a row click drops the preview of the object it replaces, and marks the entry as the page's own", () => {
  const { click, log, location } = fixture({ href: `${INDEX}?type=all&document_id=B&preview=V`, values: { ...noteA, groups: KNOWLEDGE_GROUPS } })
  click()
  assert.equal(location.searchParams.get("note_id"), "A")
  assert.equal(location.searchParams.has("document_id"), false)
  assert.equal(location.searchParams.has("preview"), false)
  assert.equal(log.history[0][0], "replace")
  assert.equal(new URL(log.frameSrc).searchParams.has("preview"), false)
})

test("opening an existing row clears the page's new-form state", () => {
  const groups = { selection: ["meeting_id"], preview: [], form: ["new"], ignore: ["viewport"] }
  const meeting = {
    url: "/org/o1/projects/p1/meetings/M",
    id: "M",
    param: "meeting_id",
    params: ["meeting_id"],
    frame: "meeting_display_frame",
    navigate: false,
    groups
  }
  const { click, log, location } = fixture({
    href: "/org/o1/projects/p1/meetings?new=meeting&search=Retro&viewport=desktop",
    indexUrl: "/org/o1/projects/p1/meetings",
    values: meeting
  })

  click()

  assert.equal(location.searchParams.get("meeting_id"), "M")
  assert.equal(location.searchParams.has("new"), false)
  assert.equal(location.searchParams.get("search"), "Retro")
  assert.equal(location.searchParams.get("viewport"), "desktop")
  assert.equal(new URL(log.frameSrc).searchParams.has("new"), false)
})

test("a preview alone in the address is no selection: the row stays unmarked on connect", () => {
  const { controller, classes } = fixture({ href: `${INDEX}?type=all&preview=A`, values: { ...noteA, groups: KNOWLEDGE_GROUPS } })
  classes.add("selected-row")
  controller.connect()
  assert.equal(classes.has("selected-row"), true, "without a selection the server's mark stands")
})
