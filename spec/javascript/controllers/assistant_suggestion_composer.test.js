import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_suggestion_composer_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "").replace("export default class", "class Composer")

function fixture(fetch = async () => { throw new Error("offline") }) {
  const listeners = {}
  const root = { querySelectorAll: () => [] }
  const field = { value: "Entwurf", events: [], focus() {}, dispatchEvent(event) { this.events.push(event.type) } }
  const revisionId = { value: "answer-1", setAttribute(_name, value) { this.value = value } }
  const analysis = { cancellations: 0, cancelRevision() { this.cancellations++ } }
  const browserWindow = { Stimulus: { getControllerForElementAndIdentifier: () => analysis } }
  const Klass = runInNewContext(`${source}\nComposer`, {
    Controller: class {}, MutationObserver: class { observe() {} disconnect() {} },
    AbortController, Event, fetch, URL, location: { origin: "http://localhost" }, window: browserWindow,
    Option: class { constructor(text, value) { this.text = text; this.value = value } },
    setTimeout, clearTimeout
  })
  const c = new Klass()
  c.element = { isConnected: true, closest: () => root, querySelector: selector => {
    if (selector === "textarea") return field
    if (selector === '[data-meeting-analysis-composer-target="revisionId"]') return revisionId
    return null
  },
    addEventListener(name, fn) { listeners[name] = fn }, removeEventListener() {} }
  c.intentTarget = { value: "" }
  c.meetingTarget = { value: "", replaceChildren() {} }
  c.modeTarget = {}; c.toolsTarget = {}; c.statusTarget = {}; c.retryTarget = {}
  c.hasRetryTarget = true
  c.urlValue = "/meetings"; c.errorValue = "Laden fehlgeschlagen"
  c.promptValue = "Leite Aufgaben ab."; c.unavailableValue = "Nicht verfügbar"; c.appendedValue = "Angehängt"
  c.pendingValue = "Bezug wird übernommen"
  c.connect()
  return { c, root, field, listeners, revisionId, analysis }
}

test("native input followed by change preserves the selected meeting and draft", () => {
  const { c, field, listeners } = fixture()
  c.intentTarget.value = "choose"
  c.meetingTarget.value = "meeting-b"
  listeners.input({ target: c.meetingTarget })
  c.select()
  assert.equal(c.intentTarget.value, "meeting-b")
  assert.equal(c.meetingTarget.value, "meeting-b")
  assert.equal(field.value, "Entwurf")
  c.disconnect()
})

test("a failed picker request can retry the same references", async () => {
  let calls = 0
  const { c, root } = fixture(async () => { calls++; throw new Error("offline") })
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:a" } }]
  await c.references()
  await c.reloadOptions()
  assert.equal(calls, 2)
  c.disconnect()
})


test("an aborted picker reloads the same references after reconnect and ignores the old response", async () => {
  const pending = []
  const { c, root } = fixture(() => new Promise(resolve => pending.push(resolve)))
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:a" } }]
  const first = c.references()
  c.disconnect()
  c.connect()
  assert.equal(pending.length, 2)
  pending[0]({ ok: true, json: async () => [{ id: "old" }] })
  await first
  assert.equal(c.meetings, undefined)
  pending[1]({ ok: true, json: async () => [{ id: "a", title: "Meeting", project: "Project" }] })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(c.meetings[0].id, "a")
  c.disconnect()
})

test("a failed fetch does not loop on mutations and a successful explicit retry clears the error", async () => {
  let calls = 0
  const { c, root } = fixture(async () => {
    if (++calls === 1) throw new Error("offline")
    return { ok: true, json: async () => [{ id: "a", title: "Meeting", project: "Project" }] }
  })
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:a" } }]
  await c.references()
  await c.references()
  assert.equal(calls, 1)
  assert.equal(c.statusTarget.textContent, "Laden fehlgeschlagen")
  await c.reloadOptions()
  assert.equal(calls, 2)
  assert.equal(c.statusTarget.textContent, "")
  assert.equal(c.retryTarget.hidden, true)
  c.disconnect()
})


test("submission is blocked only while explicit task mode has no selected meeting", () => {
  const { c, listeners } = fixture()
  let prevented = 0
  let stopped = 0
  let reported = 0
  const event = { preventDefault() { prevented++ }, stopImmediatePropagation() { stopped++ } }
  c.meetingTarget.reportValidity = () => reported++
  listeners.submit(event)
  assert.equal(prevented, 0)
  c.intentTarget.value = "choose"
  listeners.submit(event)
  assert.equal(prevented, 1)
  assert.equal(stopped, 1)
  assert.equal(reported, 1)
  c.meetingTarget.value = "a"
  c.intentTarget.value = "a"
  listeners.submit(event)
  assert.equal(prevented, 1)
  c.disconnect()
})

test("an explicit meeting entry selects that meeting and preserves an existing draft", () => {
  const { c, root, field, revisionId, analysis } = fixture()
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a Meeting:meeting-b" } }]
  c.signature = "meeting-a meeting-b"
  c.meetings = [{ id: "meeting-a" }, { id: "meeting-b" }]
  c.intentTarget.value = "meeting-b"
  c.prepareForMeeting("meeting-a")
  assert.equal(c.intentTarget.value, "meeting-a")
  assert.equal(c.meetingTarget.value, "meeting-a")
  assert.equal(field.value, "Entwurf")
  assert.equal(revisionId.value, "")
  assert.equal(analysis.cancellations, 1)
  c.disconnect()
})

test("an explicit meeting entry appends the task prompt without sending", () => {
  const { c, root, field } = fixture()
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a" } }]
  c.signature = "meeting-a"
  c.meetings = [{ id: "meeting-a" }]
  c.prepareForMeeting("meeting-a")
  assert.equal(c.intentTarget.value, "meeting-a")
  assert.equal(field.value, "Entwurf\n\nLeite Aufgaben ab.")
  assert.equal(c.statusTarget.textContent, "Angehängt")
  assert.deepEqual(field.events, ["input"])
  c.disconnect()
})

test("an explicit meeting entry waits for options matching a newly adopted reference", () => {
  const { c, root, field } = fixture()
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a Meeting:meeting-b" } }]
  c.signature = "meeting-a"
  c.meetings = [{ id: "meeting-a" }]

  c.prepareForMeeting("meeting-b")

  assert.equal(c.requestedMeetingId, "meeting-b")
  assert.equal(c.intentTarget.value, "")
  assert.notEqual(c.statusTarget.textContent, "Nicht verfügbar")

  c.signature = "meeting-a meeting-b"
  c.meetings = [{ id: "meeting-a" }, { id: "meeting-b" }]
  c.applyRequestedMeeting()

  assert.equal(c.requestedMeetingId, null)
  assert.equal(c.intentTarget.value, "meeting-b")
  assert.equal(field.value, "Entwurf\n\nLeite Aufgaben ab.")
  c.disconnect()
})

function submitEvent() {
  const counts = { prevented: 0, stopped: 0 }
  return {
    counts,
    event: { preventDefault() { counts.prevented++ }, stopImmediatePropagation() { counts.stopped++ } }
  }
}

test("submission is blocked with the pending text while the options for the requested meeting load", async () => {
  const pending = []
  const { c, root, listeners } = fixture(() => new Promise(resolve => pending.push(resolve)))
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-b" } }]
  const loading = c.references()
  c.prepareForMeeting("meeting-b")

  const blocked = submitEvent()
  listeners.submit(blocked.event)
  assert.equal(blocked.counts.prevented, 1)
  assert.equal(blocked.counts.stopped, 1)
  assert.equal(c.statusTarget.textContent, "Bezug wird übernommen")

  pending[0]({ ok: true, json: async () => [{ id: "meeting-b", title: "Meeting", project: "Project" }] })
  await loading
  assert.equal(c.requestedMeetingId, null)
  assert.equal(c.intentTarget.value, "meeting-b")
  const released = submitEvent()
  listeners.submit(released.event)
  assert.equal(released.counts.prevented, 0, "the decided request no longer holds the composer")
  c.disconnect()
})

test("a request that no options fetch is loading for does not block a normal message", () => {
  const { c, listeners } = fixture()
  c.requestedMeetingId = "meeting-b"
  c.statusTarget.textContent = "Laden fehlgeschlagen"

  const submit = submitEvent()
  listeners.submit(submit.event)

  assert.equal(submit.counts.prevented, 0)
  assert.equal(c.statusTarget.textContent, "Laden fehlgeschlagen")
  c.disconnect()
})

test("a failed options load drops its explicit request, keeps error and retry, and lets a normal message through", async () => {
  const { c, root, listeners } = fixture(async () => { throw new Error("offline") })
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-b" } }]
  const loading = c.references()
  c.prepareForMeeting("meeting-b")
  assert.equal(c.awaitingRequestedMeeting(), true)

  await loading

  assert.equal(c.requestedMeetingId, null)
  assert.equal(c.statusTarget.textContent, "Laden fehlgeschlagen")
  assert.equal(c.retryTarget.hidden, false)
  const submit = submitEvent()
  listeners.submit(submit.event)
  assert.equal(submit.counts.prevented, 0)
  assert.equal(submit.counts.stopped, 0)
  assert.equal(c.statusTarget.textContent, "Laden fehlgeschlagen", "the pending text must not replace the load error")
  c.disconnect()
})

test("a failed options load keeps a request for a meeting outside its signature", async () => {
  const { c, root } = fixture(async () => { throw new Error("offline") })
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a" } }]
  const loading = c.references()
  c.prepareForMeeting("meeting-b")

  await loading

  assert.equal(c.failedSignature, "meeting-a")
  assert.equal(c.requestedMeetingId, "meeting-b")
  c.disconnect()
})

test("an explicit meeting entry after a failed load retries the options and opens task mode", async () => {
  let calls = 0
  const { c, root } = fixture(async () => {
    if (++calls === 1) throw new Error("offline")
    return { ok: true, json: async () => [{ id: "meeting-b", title: "Meeting", project: "Project" }] }
  })
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-b" } }]
  await c.references()
  assert.equal(c.failedSignature, "meeting-b")

  const retry = c.prepareForMeeting("meeting-b")
  assert.equal(c.awaitingRequestedMeeting(), true)
  await retry

  assert.equal(calls, 2)
  assert.equal(c.requestedMeetingId, null)
  assert.equal(c.intentTarget.value, "meeting-b")
  assert.equal(c.retryTarget.hidden, true)
  c.disconnect()
})

test("removing a requested reference clears its stale pending intent", () => {
  const { c, root, field } = fixture()
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a Meeting:meeting-b" } }]
  c.signature = "meeting-a"
  c.meetings = [{ id: "meeting-a" }]
  c.prepareForMeeting("meeting-b")
  assert.equal(c.requestedMeetingId, "meeting-b")

  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a" } }]
  c.applyRequestedMeeting()
  assert.equal(c.requestedMeetingId, null)

  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a Meeting:meeting-b" } }]
  c.signature = "meeting-a meeting-b"
  c.meetings = [{ id: "meeting-a" }, { id: "meeting-b" }]
  c.applyRequestedMeeting()
  assert.equal(c.intentTarget.value, "")
  assert.equal(field.value, "Entwurf")
  c.disconnect()
})

test("removing a reference aborts its pending options load before it can restore the stale meeting", async () => {
  const pending = []
  const { c, root } = fixture((_url, options) => new Promise(resolve => pending.push({ resolve, signal: options.signal })))
  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a" } }]
  c.signature = "meeting-a"
  c.meetings = [{ id: "meeting-a" }]

  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a Meeting:meeting-b" } }]
  const staleLoad = c.references()
  assert.equal(c.pendingSignature, "meeting-a meeting-b")

  root.querySelectorAll = () => [{ dataset: { referenceKeys: "Meeting:meeting-a" } }]
  await c.references()

  assert.equal(pending[0].signal.aborted, true)
  assert.equal(c.pendingSignature, null)
  pending[0].resolve({ ok: true, json: async () => [
    { id: "meeting-a", title: "A", project: "Project" },
    { id: "meeting-b", title: "B", project: "Project" }
  ] })
  await staleLoad
  assert.deepEqual(c.meetings, [{ id: "meeting-a" }])
  c.disconnect()
})
