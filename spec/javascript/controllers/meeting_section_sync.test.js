import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/meeting_section_sync_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class SyncController")

function fixture(fetch, { event = "assistant:suggestions-changed", linksFrame = "ticket_links_meeting_a" } = {}) {
  const listeners = {}
  const dispatched = []
  const freshFrame = { childNodes: [{ text: "fresh" }] }
  const freshLinks = { childNodes: [{ text: "fresh ticket" }] }
  const currentLinks = {
    childNodes: [{ text: "old ticket" }],
    replaceChildren(...children) { this.childNodes = children }
  }
  const Controller = runInNewContext(`${source}\nSyncController`, {
    Controller: class {}, fetch, AbortController, CustomEvent,
    document: { getElementById: id => id === "ticket_links_meeting_a" ? currentLinks : null },
    DOMParser: class { parseFromString() { return { getElementById: id => id === "ticket_links_meeting_a" ? freshLinks : freshFrame } } },
    window: {
      addEventListener(name, callback) { listeners[name] = callback },
      removeEventListener() {},
      dispatchEvent(event) { dispatched.push(event); return listeners[event.type]?.(event) }
    }
  })
  const controller = new Controller()
  controller.meetingValue = "meeting-a"
  controller.urlValue = "/meeting-a"
  controller.linksFrameValue = linksFrame
  controller.eventValue = event
  controller.announceLinksValue = false
  controller.element = {
    id: "ticket_suggestions_meeting_a", isConnected: true, childNodes: [{ text: "old" }],
    replaceChildren(...children) { this.childNodes = children }
  }
  return { controller, listeners, dispatched, currentLinks }
}

test("assistant changes reload the matching meeting list from its authorized page", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: true, redirected: false, text: async () => "page" } })
  f.controller.connect()

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", runId: "run-a" } })

  assert.equal(calls, 1)
  assert.deepEqual(f.controller.element.childNodes, [{ text: "fresh" }])
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "old ticket" }])
})

test("a meeting action announces its replacement and refreshes linked tickets for that meeting", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: true, redirected: false, text: async () => "page" } })
  f.controller.announceValue = true
  f.controller.announceLinksValue = true
  f.controller.connect()
  await new Promise(resolve => setImmediate(resolve))

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-b", runId: "run-b" } })

  assert.equal(f.dispatched.length, 1)
  assert.equal(f.dispatched[0].detail.meetingId, "meeting-a")
  assert.equal(f.dispatched[0].detail.refreshLinks, true)
  assert.equal(f.controller.announceValue, false)
  assert.equal(calls, 1)
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "fresh ticket" }])
})

test("an event received during a refresh is fetched again instead of being lost", async () => {
  const pending = []
  const f = fixture(() => new Promise(resolve => pending.push(resolve)))
  f.controller.connect()

  const first = f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a" } })
  f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", refreshLinks: true } })
  assert.equal(pending.length, 1)

  pending[0]({ ok: true, redirected: false, text: async () => "first" })
  await first
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(pending.length, 2)
  pending[1]({ ok: true, redirected: false, text: async () => "second" })
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "fresh ticket" }])
})

test("a temporary fetch failure gets one retry", async () => {
  let calls = 0
  const f = fixture(async () => {
    calls++
    if (calls === 1) throw new Error("offline")
    return { ok: true, redirected: false, text: async () => "page" }
  })
  f.controller.connect()

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a" } })
  await new Promise(resolve => setImmediate(resolve))

  assert.equal(calls, 2)
  assert.deepEqual(f.controller.element.childNodes, [{ text: "fresh" }])
})

test("an ordinary queued event cannot drop a failed accept event's linked-ticket refresh", async () => {
  const pending = []
  const f = fixture(() => new Promise((resolve, reject) => pending.push({ resolve, reject })))
  f.controller.connect()

  const first = f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", refreshLinks: true } })
  f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a", refreshLinks: false } })
  pending[0].reject(new Error("offline"))
  await first
  await new Promise(resolve => setImmediate(resolve))

  assert.equal(pending.length, 2)
  pending[1].resolve({ ok: true, redirected: false, text: async () => "page" })
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "fresh ticket" }])
})

test("the refresh asks for the lean detail frame, not the whole meetings index", async () => {
  let headers
  const f = fixture(async (_url, options) => { headers = options.headers; return { ok: true, redirected: false, text: async () => "page" } })
  f.controller.connect()

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a" } })

  assert.equal(headers["Turbo-Frame"], "meeting_display_frame")
  assert.equal(headers.Accept, "text/html")
})

test("a permanent fetch failure retries exactly once and keeps the last rendering", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; throw new Error("offline") })
  f.controller.connect()

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a" } })
  for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve))

  assert.equal(calls, 2)
  assert.deepEqual(f.controller.element.childNodes, [{ text: "old" }])
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "old ticket" }])
})

test("a redirected response (lost session or access) leaves the section and linked tickets untouched", async () => {
  const f = fixture(async () => ({ ok: true, redirected: true, text: async () => "login" }))
  f.controller.connect()

  await f.listeners["assistant:suggestions-changed"]({ detail: { meetingId: "meeting-a" } })

  assert.deepEqual(f.controller.element.childNodes, [{ text: "old" }])
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "old ticket" }])
})

test("the stored-analyses section listens to its own event and has no linked-tickets frame", async () => {
  let calls = 0
  const f = fixture(async () => { calls++; return { ok: true, redirected: false, text: async () => "page" } },
                    { event: "assistant:analyses-changed", linksFrame: "" })
  f.controller.connect()

  assert.equal(f.listeners["assistant:suggestions-changed"], undefined)
  await f.listeners["assistant:analyses-changed"]({ detail: { meetingId: "meeting-a" } })

  assert.equal(calls, 1)
  assert.deepEqual(f.controller.element.childNodes, [{ text: "fresh" }])
  assert.deepEqual(f.currentLinks.childNodes, [{ text: "old ticket" }])
})
