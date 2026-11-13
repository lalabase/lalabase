import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import { setImmediate } from "node:timers/promises"
import { liveStep, redrawAddress } from "../../../app/javascript/lib/inbox_live.js"

// Exercise the actual controller with controlled network completion order.
// The browser specs cover applying its real Turbo replacements to the DOM.
const source = readFileSync(new URL("../../../app/javascript/controllers/all_inboxes_live_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class LiveController")

function events(attributes = {}) {
  const listeners = new Map()
  return {
    ...attributes,
    addEventListener(name, listener) { listeners.set(name, listener) },
    removeEventListener(name, listener) { if (listeners.get(name) === listener) listeners.delete(name) },
    emit(name) { listeners.get(name)?.() }
  }
}

const response = (stamp, body = stamp, extra = {}) => ({
  ok: true, headers: { get: name => name === "X-Inbox-Stamp" ? stamp : null }, text: async () => body, ...extra
})

async function fixture({ hidden = false } = {}) {
  const requests = [], applied = [], observers = [], timers = []
  const list = { dataset: { neoEndlessScrollFirstPageValue: "1", neoEndlessScrollPageValue: "2" } }
  const document = events({
    hidden, getElementById: () => list, importNode: node => node,
    createElement: () => ({
      set innerHTML(body) { this.content = { querySelectorAll: () => [{ action: "replace", body }] } }
    })
  })
  const window = events({ location: { href: "https://lalabase.test/inbox", origin: "https://lalabase.test" } })
  let starting = true
  const Controller = runInNewContext(`${source}\nLiveController`, {
    Controller: class {}, liveStep, redrawAddress, AbortController, URL, document, window, console,
    setTimeout(callback, delay) { const timer = { callback, delay }; timers.push(timer); return timer },
    clearTimeout(timer) { if (timer) timer.cancelled = true },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; observers.push(this) }
      observe() {}
      disconnect() { this.disconnected = true }
    },
    fetch(url, options) {
      if (starting) return Promise.resolve(response("a"))
      return new Promise((resolve, reject) => requests.push({ url, options, resolve, reject }))
    },
    Turbo: {
      StreamActions: { replace() { applied.push(this.body) } }
    }
  })
  const controller = new Controller()
  controller.element = events({ isConnected: true })
  controller.urlValue = "/inbox"
  controller.hasSignalTarget = controller.hasDrawnTarget = controller.hasBannerTarget = true
  controller.signalTarget = { dataset: { stamp: "a" } }
  controller.drawnTarget = { dataset: { stamp: "a" } }
  controller.bannerTarget = { classList: { toggle(_name, hide) { controller.bannerHidden = hide } } }
  controller.connect()
  await setImmediate()
  starting = false
  applied.length = 0
  return { controller, requests, applied, document, window, observers, list, timers }
}

test("a delayed response cannot render after disconnect, even if fetch ignores abort", async () => {
  const f = await fixture()
  const pending = f.controller.redraw("counts")
  f.controller.disconnect()
  f.window.location.href = "https://lalabase.test/org/north/inbox"
  f.requests[0].resolve(response("b"))
  await pending
  assert.equal(f.requests[0].options.signal.aborted, true)
  assert.deepEqual(f.applied, [])
  assert.equal(f.observers[0].disconnected, true)
  f.window.emit("online")
  f.document.emit("visibilitychange")
  assert.equal(f.requests.length, 1)
})

test("check context again after the response body finishes reading", async () => {
  for (const change of [
    f => { f.window.location.href += "?org=south" },
    f => { f.controller.element.isConnected = false },
    f => { f.controller.drawnTarget = { dataset: { stamp: "new-list" } } },
    f => { f.document.getElementById = () => ({ dataset: {} }) }
  ]) {
    const f = await fixture()
    let finishBody
    const pending = f.controller.redraw("counts")
    f.requests[0].resolve(response("b", null, { text: () => new Promise(resolve => { finishBody = resolve }) }))
    await setImmediate()
    change(f)
    finishBody("old response")
    await pending
    assert.deepEqual(f.applied, [])
  }
})

test("only the newest request may apply when responses finish out of order", async () => {
  const f = await fixture()
  const old = f.controller.redraw("counts")
  const fresh = f.controller.redraw("counts")
  f.requests[1].resolve(response("c", "new counts"))
  await fresh
  f.requests[0].resolve(response("b", "old counts"))
  await old
  assert.deepEqual(f.applied, ["new counts"])
  assert.equal(f.controller.counted, "c")
})

test("a new cable signal invalidates counts already in flight", async () => {
  const f = await fixture()
  const old = f.controller.redraw("counts")
  f.controller.signalTarget = { dataset: { stamp: "c" } }
  f.controller.signalTargetConnected()
  f.requests[1].resolve(response("c", "new counts"))
  await setImmediate()
  f.requests[0].resolve(response("b", "old counts"))
  await old
  assert.deepEqual(f.applied, ["new counts"])
})

test("a row-action redraw invalidates earlier counts even with unchanged stamps", async () => {
  const f = await fixture()
  const old = f.controller.redraw("counts")
  f.controller.drawnTarget = { dataset: { stamp: "a" } }
  f.controller.drawnTargetConnected()
  f.requests[0].resolve(response("b", "pre-action counts"))
  await old
  assert.deepEqual(f.applied, [])
})

test("a pending row action blocks redraws until its submit ends", async () => {
  const f = await fixture()
  const old = f.controller.redraw("list")
  f.controller.element.emit("turbo:submit-start")
  await f.controller.redraw("list")
  assert.equal(f.requests.length, 1)
  f.requests[0].resolve(response("b", "pre-action list"))
  await old
  assert.deepEqual(f.applied, [])
  f.controller.element.emit("turbo:submit-end")
  assert.equal(f.requests.length, 2)
})

test("a superseding signal preserves an explicit list refresh", async () => {
  const f = await fixture()
  const old = f.controller.redraw("list")
  f.controller.signalTarget = { dataset: { stamp: "b" } }
  f.controller.signalTargetConnected()
  assert.equal(new URL(f.requests[1].url).searchParams.has("part"), false)
  f.requests[0].resolve(response("old"))
  await old
  assert.deepEqual(f.applied, [])
})

test("visibility return refreshes even when both local stamps are equally stale", async () => {
  const f = await fixture({ hidden: true })
  f.document.hidden = false
  f.document.emit("visibilitychange")
  assert.equal(f.requests.length, 1)
  assert.equal(new URL(f.requests[0].url).searchParams.has("part"), false)
  assert.equal(new URL(f.requests[0].url).searchParams.get("through_page"), "2")
})

test("online and cable reconnect reconcile counts without moving the visible list", async () => {
  for (const resume of [
    f => f.window.emit("online"),
    f => f.observers[0].callback([{ target: { matches: () => true } }])
  ]) {
    const f = await fixture()
    resume(f)
    assert.equal(new URL(f.requests[0].url).searchParams.get("part"), "counts")
    f.requests[0].resolve(response("b"))
    await setImmediate()
    assert.equal(f.controller.signalTarget.dataset.stamp, "b")
    assert.equal(f.controller.drawnTarget.dataset.stamp, "a")
    assert.equal(f.controller.bannerHidden, false)
    assert.equal(f.requests.length, 1)
  }
})

test("reconnect while hidden defers work until visibility return", async () => {
  const f = await fixture({ hidden: true })
  f.window.emit("online")
  f.observers[0].callback([{ target: { matches: () => true } }])
  assert.equal(f.requests.length, 0)
})

test("failed reconciliation retries without another signal and backs off up to 30 seconds", async () => {
  const f = await fixture()
  f.controller.redraw("counts")
  for (const [index, delay] of [1000, 2000, 4000, 8000, 16000, 30000, 30000].entries()) {
    f.requests[index].resolve(response("b", null, { ok: false, status: 503 }))
    await setImmediate()
    assert.equal(f.controller.counted, "a")
    assert.equal(f.timers[index].delay, delay)
    f.timers[index].callback()
  }
  f.requests.at(-1).resolve(response("b", "recovered counts"))
  await setImmediate()
  assert.deepEqual(f.applied, ["recovered counts"])
  assert.equal(f.controller.counted, "b")
  assert.equal(f.controller.bannerHidden, false)
})

test("disconnect or changed context prevents a scheduled retry from fetching", async () => {
  for (const change of [f => f.controller.disconnect(), f => { f.window.location.href += "?search=new" }]) {
    const f = await fixture()
    const pending = f.controller.redraw("counts")
    f.requests[0].resolve(response(null, null, { ok: false, status: 503 }))
    await pending
    change(f)
    f.timers[0].callback()
    assert.equal(f.requests.length, 1)
  }
})

test("permanent HTTP failures do not retry", async () => {
  const f = await fixture()
  const pending = f.controller.redraw("counts")
  f.requests[0].resolve(response(null, null, { ok: false, status: 404 }))
  await pending
  assert.equal(f.timers.length, 0)
})

test("a list refresh refetches pages appended by endless scroll during the request", async () => {
  const f = await fixture()
  const pending = f.controller.redraw("list")
  f.list.dataset.neoEndlessScrollPageValue = "3"
  f.requests[0].resolve(response("b", "only two pages"))
  await setImmediate()
  assert.deepEqual(f.applied, [])
  assert.equal(new URL(f.requests[1].url).searchParams.get("through_page"), "3")
  f.requests[1].resolve(response("b", "all three pages"))
  await pending
  assert.deepEqual(f.applied, ["all three pages"])
})

test("redirects and responses without a stamp never replace inbox content", async () => {
  for (const answer of [response("b", "login", { redirected: true }), response(null, "no stamp")]) {
    const f = await fixture()
    const pending = f.controller.redraw("counts")
    f.requests[0].resolve(answer)
    await pending
    assert.deepEqual(f.applied, [])
  }
})
