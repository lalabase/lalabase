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
function marker(type, id, label, { insideClosed = [], visible = true } = {}) {
  return {
    dataset: { assistantContext: id, assistantContextType: type, assistantContextLabel: label },
    closest: selector => (insideClosed.includes(selector) ? {} : null),
    checkVisibility: () => visible
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

// A closed lane keeps its box (it slides at 0px), so only its class says it is shut; a
// closed third lane is display:none, which the browser answers (checkVisibility).
test("skips what a closed lane or a closed panel still holds", () => {
  const closedPanel = marker("Meeting", "m1", "Weekly", { visible: false })
  const closedLane = marker("Ticket", "t1", "#1", { insideClosed: [".layout.hide-content"] })

  assert.deepEqual(keysOf(controllerFor([TICKET, closedPanel])), ["Ticket:t1"])
  assert.deepEqual(keysOf(controllerFor([closedLane, MEETING])), ["Meeting:m1"])
})

test("skips a marker the reader cannot see: the column behind the other tab at the narrow stage", () => {
  const behindTheTicket = marker("Meeting", "m1", "Weekly", { visible: false })

  assert.deepEqual(keysOf(controllerFor([TICKET, behindTheTicket])), ["Ticket:t1"])
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

// Any write on its way holds the strip, not only one of this page's: taking an offer
// submits the same form, and a second requestSubmit stops the first.
test("a context on its way elsewhere holds back this page's offer too", () => {
  assert.equal(offering([TICKET, MEETING], { pending: "Meeting:other" }).shown, null)
})

test("refusing the ticket by hand brings up the meeting", () => {
  const { controller } = offering([TICKET, MEETING])
  const shown = []
  controller.showOffer = context => shown.push(context.key)
  controller.hideOffer = () => shown.push(null)
  controller.offerTarget = { dataset: { contextId: "Ticket:t1" }, contains: () => false }
  controller.focusComposer = () => {}

  controller.dismissOffer()

  assert.equal(shown.at(-1), "Meeting:m1")
  assert.equal(controller.dismissedContexts.has("Ticket:t1"), true)
})

// The draft of a new conversation holds up to referenceLimit objects: at the limit the
// strip stays down, one below it the next object is offered.
test("a new conversation's draft offers up to its limit, and not one more", () => {
  const atLimit = (limit, standing) => {
    const controller = controllerFor([TICKET, MEETING])
    Object.assign(controller, {
      hasOfferTarget: true, chatFrameSeen: true, pendingContext: null,
      dismissedContexts: new Set(), refusedContexts: new Set(),
      draftSubmitting: () => false, canOpen: () => true, openThreadId: () => null,
      hasDraftReferencesTarget: true,
      draftReferencesTarget: { dataset: { referenceLimit: String(limit) } },
      standingReferenceKeys: () => standing.join(" "),
      standingKeySet: () => new Set(standing)
    })
    const shown = []
    controller.showOffer = context => shown.push(context.key)
    controller.hideOffer = () => shown.push(null)
    controller.offerPageContext()
    return shown.at(-1)
  }

  assert.equal(atLimit(2, ["Ticket:t1"]), "Meeting:m1")
  assert.equal(atLimit(1, ["Ticket:t1"]), null)
})

// Taking the strip asks the page again: the meeting, second on the page, is taken as
// well as the ticket; an object the page no longer names is not.
test("taking the offer takes the meeting beside the ticket, not only the page's first object", () => {
  const taking = (markers, offered) => {
    const controller = controllerFor(markers)
    controller.offerTarget = { dataset: { contextId: offered } }
    const adopted = []
    let reoffered = false
    controller.hideOffer = () => {}
    controller.adoptContext = event => adopted.push(event.detail.referenceKey)
    controller.offerPageContext = () => { reoffered = true }
    controller.takeOffer()
    return { adopted, reoffered }
  }

  assert.deepEqual(taking([TICKET, MEETING], "Meeting:m1"), { adopted: ["Meeting:m1"], reoffered: false })
  assert.deepEqual(taking([TICKET], "Meeting:m1"), { adopted: [], reoffered: true })
})

// Without a thread yet, the object goes into the new conversation's draft. The page is
// asked for its label there, and the meeting is on the page as much as the ticket.
test("adopting into a new conversation finds the meeting beside the ticket", () => {
  const adopting = (markers, referenceKey) => {
    const controller = controllerFor(markers)
    const drafted = []
    Object.assign(controller, {
      hasContextFormTarget: true,
      canOpen: () => true,
      open: () => {},
      whenComposerReady: callback => callback(),
      standingKeySet: () => new Set(),
      openThreadId: () => null,
      addDraftReference: context => drafted.push(context.key)
    })
    controller.adoptContext({ detail: { referenceKey } })
    return drafted
  }

  assert.deepEqual(adopting([TICKET, MEETING], "Meeting:m1"), ["Meeting:m1"])
  assert.deepEqual(adopting([TICKET], "Meeting:m1"), [])
})
