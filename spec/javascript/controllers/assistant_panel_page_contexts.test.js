// What: the objects a page offers to the assistant (assistant_panel_controller#pageContexts
//   and #offerPageContext), with the meeting open beside a ticket
//   (doc/ticket_meeting_panel_plan.md, S3).
// Type: node:test over the controller's source with a fake document; no browser.
// Why: until S3 the panel read only the FIRST marker of the page. With the meeting beside
//   the ticket the page names two objects, and the second one was never offered. And a
//   closed lane must not offer what it no longer shows.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_panel_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class AssistantPanelController")

// A marker as the page renders it (AssistantContextHelper), sitting inside the given
// ancestors: closest() answers for the selectors the controller asks about.
function marker(type, id, label, { insideClosed = [] } = {}) {
  return {
    dataset: { assistantContext: id, assistantContextType: type, assistantContextLabel: label },
    closest: selector => (insideClosed.includes(selector) ? {} : null)
  }
}

// The controller runs in its own realm: its arrays are not this realm's arrays.
const keysOf = controller => Array.from(controller.pageContexts(), context => context.key)

function controllerFor(markers) {
  const document = { querySelectorAll: () => markers, activeElement: null }
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, { Controller: class {}, document, Event })
  const controller = new Controller()
  controller.element = { contains: () => false }
  return controller
}

const TICKET = marker("Ticket", "t1", "#1 Navigation")
const TICKET_AGAIN = marker("Ticket", "t1", "#1 Navigation")
const MEETING = marker("Meeting", "m1", "Weekly with the client")

test("names every object of the page once, in page order", () => {
  const controller = controllerFor([TICKET, TICKET_AGAIN, MEETING])

  assert.deepEqual(keysOf(controller), ["Ticket:t1", "Meeting:m1"])
})

test("skips what a closed lane or a closed panel still holds", () => {
  const closedPanel = marker("Meeting", "m1", "Weekly", { insideClosed: [".layout.hide-panel > .column.panel"] })
  const closedLane = marker("Ticket", "t1", "#1", { insideClosed: [".layout.hide-content"] })

  assert.deepEqual(keysOf(controllerFor([TICKET, closedPanel])), ["Ticket:t1"])
  assert.deepEqual(keysOf(controllerFor([closedLane, MEETING])), ["Meeting:m1"])
})

test("skips a marker without id, type or label", () => {
  assert.deepEqual(keysOf(controllerFor([marker("Ticket", "", "#1"), MEETING])), ["Meeting:m1"])
})

// offerPageContext with everything around it stubbed: which context does the strip show?
function offering(markers, { standing = [], pending = null, dismissed = [], refused = [] } = {}) {
  const controller = controllerFor(markers)
  controller.hasOfferTarget = true
  controller.draftSubmitting = () => false
  controller.chatFrameSeen = true
  controller.canOpen = () => true
  controller.openThreadId = () => "thread"
  controller.hasDraftReferencesTarget = false
  controller.standingReferenceKeys = () => standing.join(" ") || null
  controller.standingKeySet = () => new Set(standing)
  controller.pendingContext = pending
  controller.dismissedContexts = new Set(dismissed)
  controller.refusedContexts = new Set(refused)
  const shown = []
  controller.showOffer = context => shown.push(context.key)
  controller.hideOffer = () => shown.push(null)
  controller.offerPageContext()
  return { shown: shown.at(-1), controller }
}

test("offers the ticket first, then the meeting beside it", () => {
  assert.equal(offering([TICKET, MEETING]).shown, "Ticket:t1")
  assert.equal(offering([TICKET, MEETING], { standing: ["Ticket:t1"] }).shown, "Meeting:m1")
  assert.equal(offering([TICKET, MEETING], { standing: ["Ticket:t1", "Meeting:m1"] }).shown, null)
})

test("offers the meeting when the ticket was refused, by hand or by the server", () => {
  assert.equal(offering([TICKET, MEETING], { dismissed: ["Ticket:t1"] }).shown, "Meeting:m1")
  assert.equal(offering([TICKET, MEETING], { refused: ["Ticket:t1"] }).shown, "Meeting:m1")
})

test("holds the strip back while one of them is on its way, and lets go once it stands", () => {
  assert.equal(offering([TICKET, MEETING], { pending: "Ticket:t1" }).shown, null)

  const { shown, controller } = offering([TICKET, MEETING], { pending: "Ticket:t1", standing: ["Ticket:t1"] })
  assert.equal(shown, "Meeting:m1")
  assert.equal(controller.pendingContext, null)
})

test("a context on its way elsewhere does not hold back this page's offer", () => {
  assert.equal(offering([TICKET, MEETING], { pending: "Meeting:other" }).shown, "Ticket:t1")
})
