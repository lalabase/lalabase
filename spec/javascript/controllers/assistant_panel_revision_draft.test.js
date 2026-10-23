// The panel replaces its frame after navigation while an answer is outstanding.
// A revision is a draft even before typing; its binding must never cross chats.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_panel_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class AssistantPanelController")

function field(chatId, text = "", id = "", key = "") {
  const inputs = new Map([
    ["chatpost[revision_answer_id]", { value: id }],
    ["chatpost[revision_answer_key]", { value: key }]
  ])
  return {
    value: text, inputs, events: [],
    form: { action: `/chats/${chatId}/chatposts`, elements: { namedItem: name => inputs.get(name) } },
    dispatchEvent(event) { this.events.push(event.type) },
    focus() {}
  }
}

function fixture(original) {
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, {
    Controller: class {}, document: { activeElement: null }, Event
  })
  const controller = new Controller()
  let current = original
  let onLoad
  controller.element = { addEventListener: (_type, callback) => { onLoad = callback } }
  controller.awaitingAnswerMarker = () => "pending-question"
  controller.claimResync = () => true
  controller.composerField = () => current
  controller.resyncUrl = () => "/assistant/panel"
  controller.frameTarget = { getAttribute: () => "/assistant/panel", reload() {} }
  return { controller, replace(next) { current = next; onLoad() } }
}

test("a selected revision survives frame replacement even before any text is typed", () => {
  const original = field("one", "", "selected-answer", "selected-key")
  const f = fixture(original)
  f.controller.resyncIfAwaitingAnswer()
  const restored = field("one")
  f.replace(restored)
  assert.equal(restored.value, "")
  assert.equal(restored.inputs.get("chatpost[revision_answer_id]").value, "selected-answer")
  assert.equal(restored.inputs.get("chatpost[revision_answer_key]").value, "selected-key")
  assert.deepEqual(restored.events, ["input"], "the composer must refresh its visible revision state")
})

test("a frame response for another chat does not inherit the previous draft or revision", () => {
  const f = fixture(field("one", "Private draft", "selected-answer", "selected-key"))
  f.controller.resyncIfAwaitingAnswer()
  const other = field("two", "Other draft", "other-answer", "other-key")
  f.replace(other)
  assert.equal(other.value, "Other draft")
  assert.equal(other.inputs.get("chatpost[revision_answer_id]").value, "other-answer")
  assert.equal(other.inputs.get("chatpost[revision_answer_key]").value, "other-key")
  assert.deepEqual(other.events, [])
})

test("a full draft reference collection explains why an explicit intent was not adopted or activated", () => {
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, { Controller: class {}, Event })
  const controller = new Controller()
  controller.hasDraftReferencesTarget = true
  controller.hasReferenceStatusTarget = true
  controller.draftSubmitting = () => false
  controller.draftReferencesTarget = { dataset: { referenceLimit: "2", referenceLimitLabel: "Collection full" } }
  controller.referenceStatusTarget = { hidden: true, textContent: "" }
  controller.standingKeySet = () => new Set(["Meeting:a", "Meeting:b"])
  controller.hasContextFormTarget = true
  controller.canOpen = () => true
  controller.open = () => {}
  controller.whenComposerReady = callback => callback()
  controller.openThreadId = () => null
  controller.pageContexts = () => [{ key: "Meeting:c", label: "Meeting C" }]
  let activated = 0
  controller.fulfilMeetingIntent = () => activated++

  controller.adoptContext({ detail: { referenceKey: "Meeting:c", intent: "analysis" } })

  assert.equal(controller.referenceStatusTarget.hidden, false)
  assert.equal(controller.referenceStatusTarget.textContent, "Collection full")
  assert.equal(activated, 0)
})

test("a refused scope write clears its pending intent without activating it", () => {
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, {
    Controller: class {}, Event, requestAnimationFrame: callback => callback()
  })
  const controller = new Controller()
  controller.pendingContext = "Meeting:c"
  controller.pendingMeetingIntents = new Map([["Meeting:c", "ticket-suggestions"]])
  controller.refusedContexts = new Set()
  controller.standingReferenceKeys = () => "Meeting:a Meeting:b"
  controller.standingKeySet = () => new Set(["Meeting:a", "Meeting:b"])
  controller.offerPageContext = () => {}
  controller.composerField = () => null
  let activated = 0
  controller.fulfilMeetingIntent = () => activated++

  controller.settleAfterScopeWrite({ ours: true, key: "Meeting:c", refused: true })

  assert.equal(activated, 0)
  assert.equal(controller.pendingMeetingIntents.has("Meeting:c"), false)
  assert.equal(controller.refusedContexts.has("Meeting:c"), true)
})

// An OPEN THREAD, wired through the real connect(): the submit-end and capture
// submit listeners are the ones the panel registers, not direct method calls.
// Deliberately without a draftReferences target -- DraftReferencesComponent
// renders for a new chat only, and a thread is where a pending intent occurs.
function threadFixture() {
  const listeners = {}
  const frames = []
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, {
    Controller: class {}, Event, CustomEvent, FULL_PAGE_BELOW_PX: 1024,
    requestAnimationFrame: callback => frames.push(callback),
    MutationObserver: class { observe() {} disconnect() {} },
    window: { innerWidth: 1400, matchMedia: () => ({ addEventListener() {} }), addEventListener() {} },
    document: { activeElement: null, addEventListener() {}, documentElement: { hasAttribute: () => true } }
  })
  const controller = new Controller()
  controller.element = {
    contains: () => true,
    addEventListener(type, callback, capture) { (listeners[type] ||= []).push({ callback, capture: Boolean(capture) }) }
  }
  controller.restoreTranscriptScroll = () => {}
  controller.render = () => {}
  controller.connect()

  let standing = "Meeting:a"
  const submissions = []
  const fulfilled = []
  const status = { hidden: true, textContent: "", dataset: { pendingReferenceLabel: "Bezug wird übernommen" } }
  const composerForm = { id: "composer", querySelector: selector => (selector === "[data-composer-status]" ? status : null) }
  controller.standingReferenceKeys = () => standing
  controller.hasContextFormTarget = true
  controller.contextFieldTarget = { value: "" }
  controller.contextFormTarget = { id: "context", action: "", requestSubmit() { submissions.push(controller.contextFieldTarget.value) } }
  controller.threadUrlValue = "/assistant_chats"
  controller.canOpen = () => true
  controller.open = () => {}
  controller.whenComposerReady = callback => callback()
  controller.openThreadId = () => "thread-1"
  controller.offerPageContext = () => {}
  controller.composerField = () => ({ form: composerForm })
  controller.fulfilMeetingIntent = (intent, key) => fulfilled.push([intent, key])

  return {
    controller, status, composerForm, submissions, fulfilled,
    adopt: (referenceKey, intent) => controller.adoptContext({ detail: { referenceKey, intent } }),
    // What Turbo 8 dispatches: { formSubmission, ...result }. An aborted request
    // has no result at all, so it passes no further detail.
    submitEnd(key, result = {}) {
      const event = { target: controller.contextFormTarget, detail: { formSubmission: { body: new Map([["key", key]]) }, ...result } }
      listeners["turbo:submit-end"].forEach(({ callback }) => callback(event))
    },
    respond(key) { this.submitEnd(key, { success: true, fetchResponse: {} }) },
    renderChips(keys) { standing = keys },
    flushFrames() { while (frames.length) frames.shift()() },
    submit(target) {
      const event = { target, prevented: 0, stopped: 0, preventDefault() { this.prevented++ }, stopImmediatePropagation() { this.stopped++ } }
      listeners.submit.filter(listener => listener.capture).forEach(({ callback }) => callback(event))
      return event
    }
  }
}

test("a successful scope write fulfils its pending intent once and removes it", () => {
  const f = threadFixture()

  f.adopt("Meeting:c", "ticket-suggestions")
  assert.deepEqual(f.submissions, ["Meeting:c"])
  f.respond("Meeting:c")
  // The stream replaces the chip row only after submit-end.
  f.renderChips("Meeting:a Meeting:c")
  f.flushFrames()

  assert.deepEqual(f.fulfilled, [["ticket-suggestions", "Meeting:c"]])
  assert.equal(f.controller.pendingMeetingIntents.has("Meeting:c"), false)
  assert.equal(f.controller.pendingContext, null)
})

test("a pending intent blocks only the composer, with the pending-reference text in an open thread", () => {
  const f = threadFixture()
  f.adopt("Meeting:c", "analysis")

  const card = f.submit({ id: "suggestion-card-accept" })
  const context = f.submit(f.controller.contextFormTarget)
  assert.equal(card.prevented + card.stopped, 0, "suggestion cards, chips and thread actions keep working")
  assert.equal(context.prevented + context.stopped, 0)
  assert.equal(f.status.hidden, true)

  const composer = f.submit(f.composerForm)
  assert.equal(composer.prevented, 1)
  assert.equal(composer.stopped, 1)
  assert.equal(f.controller.hasDraftReferencesTarget, undefined)
  assert.equal(f.status.hidden, false)
  assert.equal(f.status.textContent, "Bezug wird übernommen")

  f.respond("Meeting:c")
  f.renderChips("Meeting:a Meeting:c")
  f.flushFrames()
  assert.equal(f.status.hidden, true, "the explanation goes with the pending intent")
  assert.equal(f.submit(f.composerForm).prevented, 0)
})

test("a second adopt for the same pending key updates its intent without resubmitting", () => {
  const f = threadFixture()

  f.adopt("Meeting:c", "analysis")
  f.adopt("Meeting:c", "ticket-suggestions")
  f.adopt("Meeting:c")
  assert.deepEqual(f.submissions, ["Meeting:c"], "a resubmit would abort the write that carries the intent")
  assert.equal(f.controller.pendingMeetingIntents.get("Meeting:c"), "ticket-suggestions")

  f.respond("Meeting:c")
  // Answer in, settle still watching the row: the click still rides along.
  f.adopt("Meeting:c", "analysis")
  assert.deepEqual(f.submissions, ["Meeting:c"])
  f.renderChips("Meeting:a Meeting:c")
  f.flushFrames()

  assert.deepEqual(f.fulfilled, [["analysis", "Meeting:c"]])
  assert.equal(f.controller.pendingMeetingIntents.size, 0)
})

test("an aborted submission superseded by a newer one for the same key leaves the intent to the newer settle", () => {
  const f = threadFixture()
  f.adopt("Meeting:c", "analysis")
  f.adopt("Meeting:d")
  f.adopt("Meeting:c", "ticket-suggestions")
  assert.deepEqual(f.submissions, ["Meeting:c", "Meeting:d", "Meeting:c"])

  // Each requestSubmit aborted the one before it: both end without a result.
  f.submitEnd("Meeting:c")
  f.submitEnd("Meeting:d")
  f.flushFrames()
  assert.equal(f.controller.pendingMeetingIntents.get("Meeting:c"), "ticket-suggestions")
  assert.equal(f.controller.pendingContext, "Meeting:c")
  assert.equal(f.submit(f.composerForm).prevented, 1)
  assert.deepEqual(f.fulfilled, [])

  f.respond("Meeting:c")
  f.renderChips("Meeting:a Meeting:c")
  f.flushFrames()
  assert.deepEqual(f.fulfilled, [["ticket-suggestions", "Meeting:c"]])
  assert.equal(f.controller.pendingMeetingIntents.size, 0)
})

test("a scope write aborted without a successor (a page visit) releases the composer", () => {
  const f = threadFixture()
  f.adopt("Meeting:c", "analysis")
  f.submit(f.composerForm)

  f.submitEnd("Meeting:c")
  f.flushFrames()

  assert.equal(f.controller.pendingMeetingIntents.size, 0)
  assert.equal(f.controller.pendingContext, null)
  assert.deepEqual(f.fulfilled, [])
  assert.equal(f.status.hidden, true)
  assert.equal(f.submit(f.composerForm).prevented, 0)
})

test("an intent fulfilled against an already standing key replaces the one waiting for its settle", () => {
  const f = threadFixture()
  f.adopt("Meeting:c", "analysis")
  f.respond("Meeting:c")
  f.renderChips("Meeting:a Meeting:c")
  // The offer's guard 4 clears the slot once the chip stands.
  f.controller.pendingContext = null

  f.adopt("Meeting:c", "ticket-suggestions")
  f.flushFrames()

  // The late settle still calls in, but without an intent -- a no-op there.
  assert.deepEqual(f.fulfilled.filter(([intent]) => intent), [["ticket-suggestions", "Meeting:c"]])
  assert.equal(f.controller.pendingMeetingIntents.size, 0)
})

test("an in-flight first message explains why references and intent stay unchanged", () => {
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, { Controller: class {}, Event })
  const controller = new Controller()
  controller.hasDraftReferencesTarget = true
  controller.hasReferenceStatusTarget = true
  controller.draftSubmitting = () => true
  controller.draftReferencesTarget = { dataset: { referenceBusyLabel: "Message in flight" } }
  controller.referenceStatusTarget = { hidden: true, textContent: "" }

  controller.addDraftReference({ key: "Meeting:c" })

  assert.equal(controller.referenceStatusTarget.hidden, false)
  assert.equal(controller.referenceStatusTarget.textContent, "Message in flight")
})
