import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_suggestion_result_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class ResultController")

function fixture(fetch, { frame = null, element = null, activeElement = null, observe = false } = {}) {
  let now = 100000
  let intersection
  const events = {}
  const scheduled = []
  const delays = []
  const dispatched = []
  const Controller = runInNewContext(`${source}\nResultController`, {
    Controller: class {}, fetch, AbortController, Date: { now: () => now },
    IntersectionObserver: observe ? class { constructor(callback) { intersection = callback } observe() {} disconnect() {} } : undefined,
    CustomEvent, document: { hidden: false }, window: { document: { activeElement }, addEventListener(name, callback) { events[name] = callback }, removeEventListener() {}, dispatchEvent(event) { dispatched.push(event) } },
    DOMParser: class { parseFromString() { return { getElementById: () => frame } } },
    setTimeout: (callback, delay) => { delays.push(delay); return scheduled.push(callback) }, clearTimeout() {}
  })
  const c = new Controller()
  let replacements = 0
  c.digestValue = element?.dataset?.assistantSuggestionResultDigestValue
  c.errorValue = "Unavailable"
  c.activeValue = true
  c.announceLinksValue = false
  c.urlValue = "/authorized/result"
  c.element = element || {}
  Object.assign(c.element, {
    isConnected: true, id: "result", getClientRects: () => [1],
    replaceChildren(...children) { replacements++; this.childNodes = children }
  })
  Object.defineProperty(c.element, "textContent", { set(value) { replacements++; this.childNodes = [{ text: value }] } })
  c.generation = 1
  return { c, scheduled, delays, events, dispatched, advance(ms) { now += ms }, intersect(visible) { intersection([{ isIntersecting: visible }]) }, get replacements() { return replacements } }
}

// A small DOM double: selectors expose rows and their controls; serialized
// content includes the details state, so the no-change check runs after restore.
function resultFrame({ state = "open", open = false, actions = ["/accept", "/dismiss"], readable = true } = {}) {
  const row = { dataset: { suggestionId: "proposal-1" } }
  const control = tagName => ({ tagName, focused: false, focus() { this.focused = true } })
  row.details = { open, closest: () => row }
  row.summary = { ...control("SUMMARY"), closest: () => row }
  row.forms = actions.map(action => {
    const form = { getAttribute: () => action }
    form.button = { ...control("BUTTON"), form }
    form.querySelector = () => form.button
    return form
  })
  row.querySelector = selector => selector === "details" ? row.details : row.summary
  const frame = {
    childNodes: [{ state, rows: readable ? [row] : [] }],
    dataset: { assistantSuggestionResultActiveValue: String(readable && state === "open"), assistantSuggestionResultDigestValue: state },
    querySelectorAll(selector) {
      const rows = this.childNodes.flatMap(child => child.rows)
      if (selector === "[data-suggestion-id]") return rows
      if (selector === "form") return rows.flatMap(row => row.forms)
      return rows.filter(row => row.details.open).map(row => row.details)
    },
    contains(node) {
      return this.querySelectorAll("[data-suggestion-id]").some(row => row.summary === node || row.forms.some(form => form.button === node))
    },
    get innerHTML() {
      return JSON.stringify(this.childNodes.map(child => ({ state: child.state, rows: child.rows.map(row => ({
        id: row.dataset.suggestionId, open: row.details.open, actions: row.forms.map(form => form.getAttribute("action"))
      })) })))
    }
  }
  return { frame, row }
}

const successfulResponse = async () => ({ ok: true, text: async () => "result" })

test("a closed panel does not fetch result content", async () => {
  const f = fixture(() => assert.fail("closed panels must not fetch"))
  f.c.element.getClientRects = () => []
  await f.c.refresh()
  assert.equal(f.replacements, 0)
})

test("an in-flight response cannot update a panel closed before it arrives", async () => {
  let complete
  const f = fixture(() => new Promise(resolve => { complete = resolve }))
  const pending = f.c.refresh()
  f.c.element.getClientRects = () => []
  complete({ ok: false, status: 403 })
  await pending
  assert.equal(f.replacements, 0)
})

test("a card hidden during a forced refresh remains stale and catches up when shown", async () => {
  let complete
  let calls = 0
  const old = resultFrame()
  const fresh = resultFrame({ state: "updated", actions: ["/dismiss"] })
  const f = fixture(() => {
    calls++
    if (calls === 1) return new Promise(resolve => { complete = resolve })
    return successfulResponse()
  }, { element: old.frame, frame: fresh.frame })
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"
  f.c.connect()

  const pending = f.c.refresh(f.c.generation, true)
  f.c.element.getClientRects = () => []
  complete({ ok: true, text: async () => "stale response" })
  await pending

  assert.equal(f.replacements, 0)
  assert.equal(f.c.stale, true)
  f.c.element.getClientRects = () => [1]
  await f.events.focus()
  assert.equal(calls, 2)
  assert.equal(f.replacements, 1)
  assert.match(f.c.element.innerHTML, /updated/)
})

test("revoked access and login redirects clear previously displayed results", async () => {
  for (const response of [{ ok: false, status: 403 }, { ok: true, redirected: true, text: async () => "login" }]) {
    const f = fixture(async () => response)
    await f.c.refresh()
    assert.equal(f.replacements, 1)
    assert.equal(f.c.activeValue, false)
    assert.equal(f.scheduled.length, 0)
  }
})

test("a disconnected request cannot rearm polling after the same element reconnects", async () => {
  let complete
  const f = fixture(() => new Promise(resolve => { complete = resolve }))
  const pending = f.c.refresh()
  f.c.disconnect()
  f.c.connect()
  complete({ ok: false, status: 403 })
  await pending
  assert.equal(f.replacements, 0)
  assert.equal(f.scheduled.length, 1)
})

test("focused summaries cannot suppress superseded state and surviving focus is restored", async () => {
  const old = resultFrame({ open: true })
  const fresh = resultFrame({ state: "superseded", actions: [] })
  const f = fixture(successfulResponse, { element: old.frame, frame: fresh.frame, activeElement: old.row.summary })
  await f.c.refresh()
  assert.equal(f.replacements, 1)
  assert.match(f.c.element.innerHTML, /superseded/)
  assert.doesNotMatch(f.c.element.innerHTML, /\/accept/)
  assert.equal(fresh.row.details.open, true)
  assert.equal(fresh.row.summary.focused, true)
  assert.equal(f.c.activeValue, false)
})

test("a successful redacted response clears focused content after meeting access is revoked", async () => {
  const old = resultFrame()
  const fresh = resultFrame({ state: "unavailable", readable: false })
  const f = fixture(successfulResponse, { element: old.frame, frame: fresh.frame, activeElement: old.row.forms[0].button })
  await f.c.refresh()
  assert.equal(f.replacements, 1)
  assert.match(f.c.element.innerHTML, /unavailable/)
  assert.doesNotMatch(f.c.element.innerHTML, /proposal-1|\/accept/)
  assert.equal(f.c.activeValue, false)
  assert.equal(f.scheduled.length, 0)
})

test("unchanged content retains its DOM and focus after restoring expanded details", async () => {
  const old = resultFrame({ open: true })
  const fresh = resultFrame()
  const f = fixture(successfulResponse, { element: old.frame, frame: fresh.frame, activeElement: old.row.summary })
  await f.c.refresh()
  assert.equal(f.replacements, 0)
  assert.equal(old.row.details.open, true)
  assert.equal(f.scheduled.length, 1)
})

test("a surviving button regains focus by its form action when surrounding results change", async () => {
  const old = resultFrame()
  const fresh = resultFrame({ state: "updated", actions: ["/dismiss", "/accept"] })
  const f = fixture(successfulResponse, { element: old.frame, frame: fresh.frame, activeElement: old.row.forms[0].button })
  await f.c.refresh()
  assert.equal(f.replacements, 1)
  assert.equal(fresh.row.forms[1].button.focused, true)
  assert.equal(fresh.row.forms[0].button.focused, false)
})


test("completed open proposals never poll until explicitly refreshed", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: false, status: 500 } })
  f.c.activeValue = false
  f.c.connect()
  await f.c.refresh()
  assert.equal(calls, 0)
  assert.equal(f.scheduled.length, 0)
  await f.c.refresh(f.c.generation, true)
  assert.equal(calls, 1)
  assert.equal(f.scheduled.length, 0)
})

test("a change from the meeting refreshes a completed assistant result immediately", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: false, status: 500 } })
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"
  f.c.connect()

  await f.events["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", sourceId: "meeting-frame" } })

  assert.equal(calls, 1)
})

test("an action response announces its changed meeting once", () => {
  const f = fixture(async () => ({ ok: false, status: 500 }))
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"
  f.c.announceValue = true

  f.c.connect()

  assert.equal(f.dispatched.length, 1)
  assert.equal(f.dispatched[0].type, "assistant:suggestions-changed")
  assert.equal(f.dispatched[0].detail.meetingId, "meeting-a")
  assert.equal(f.dispatched[0].detail.refreshLinks, false)
  assert.equal(f.c.announceValue, false)
})

test("offscreen cards do not fetch or rearm a timer", async () => {
  const f = fixture(() => assert.fail("offscreen fetch"))
  f.c.inViewport = false
  await f.c.refresh()
  assert.equal(f.scheduled.length, 0)
})

test("active polling backs off to thirty seconds and respects throttling", async () => {
  const f = fixture(async () => ({ ok: false, status: 500 }))
  f.c.connect()
  for (let i = 0; i < 5; i++) await f.c.refresh()
  assert.deepEqual(f.delays, [4000, 8000, 16000, 30000, 30000, 30000])
  const throttled = fixture(async () => ({ ok: false, status: 429 }))
  await throttled.c.refresh()
  assert.deepEqual(throttled.delays, [60000])
})

test("randomized CSRF tokens do not rebuild unchanged results", async () => {
  const old = resultFrame({ open: true })
  const fresh = resultFrame()
  fresh.frame.childNodes.push({ csrf: "new-token" })
  const f = fixture(successfulResponse, { element: old.frame, frame: fresh.frame })
  await f.c.refresh()
  assert.equal(f.replacements, 0)
})


test("automatic focus, visibility and scroll refreshes share a sixty-second minimum", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: false, status: 500 } }, { observe: true })
  f.c.activeValue = false
  f.c.connect()
  f.intersect(true)
  f.advance(60000)
  await f.events.focus()
  assert.equal(calls, 1)
  for (let i = 0; i < 5; i++) {
    f.advance(1000)
    await f.c.onVisible()
    f.intersect(false)
    f.intersect(true)
  }
  assert.equal(calls, 1)
  f.advance(55000)
  await f.events.focus()
  assert.equal(calls, 2)
  // An explicit status action remains immediate.
  await f.c.reload()
  assert.equal(calls, 3)
})

test("a permanent card reconnect does not turn its first observation into a refresh", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: false, status: 500 } }, { observe: true })
  f.c.activeValue = false
  f.c.connect()
  f.intersect(true)
  for (let i = 0; i < 3; i++) {
    f.advance(60000)
    f.c.disconnect()
    f.c.connect()
    f.intersect(true)
  }
  assert.equal(calls, 0)
})

test("a run that starts in the assistant is announced once per page, not on every reconnect", () => {
  const f = fixture(async () => ({ ok: false, status: 500 }))
  f.c.activeValue = true
  f.c.meetingValue = "meeting-a"

  f.c.connect()
  f.c.disconnect()
  f.c.connect()

  assert.equal(f.dispatched.length, 1)
  assert.equal(f.dispatched[0].type, "assistant:suggestions-changed")
  assert.deepEqual({ ...f.dispatched[0].detail }, { runId: "result", meetingId: "meeting-a", refreshLinks: false })
})

test("a completed card does not announce itself on connect", () => {
  const f = fixture(async () => ({ ok: false, status: 500 }))
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"

  f.c.connect()

  assert.equal(f.dispatched.length, 0)
})

test("a meeting change received while the card is hidden refreshes as soon as it is visible again", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: false, status: 500 } }, { observe: true })
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"
  f.c.connect()
  f.intersect(false)

  await f.events["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", sourceId: "meeting-frame" } })
  assert.equal(calls, 0)

  // Well inside the sixty-second automatic minimum: the pending change still wins.
  f.advance(1000)
  f.intersect(true)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(calls, 1)
})

test("a meeting change received during a request is fetched again once that request settles", async () => {
  const pending = []
  const f = fixture(() => new Promise(resolve => pending.push(resolve)))
  f.c.activeValue = false
  f.c.meetingValue = "meeting-a"
  f.c.connect()

  const first = f.c.reload()
  await f.events["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", sourceId: "meeting-frame" } })
  assert.equal(pending.length, 1)

  pending[0]({ ok: false, status: 500 })
  await first
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(pending.length, 2)
  pending[1]({ ok: false, status: 500 })
  await new Promise(resolve => setImmediate(resolve))
})
