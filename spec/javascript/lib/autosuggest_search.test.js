// What: the server search of NeoAutosuggest (lib/autosuggest_search.js), used by the
//   ticket picker of the "Link" modal (doc/ticket_relations_plan.md, revision 4, §7).
// Why:  with a server list the options change under the user, and the old picker restored
//   the chosen text from whatever list was showing. Review 5 asked for five cases, all
//   invisible to a server spec, and spec/system does not run in CI while this file does:
//   answers in reverse order, no results, a network error, a new search after a choice,
//   and reopening after a validation error (422).
import { test } from "node:test"
import assert from "node:assert/strict"
import { ServerSearch, parseOptions, searchUrl } from "../../../app/javascript/lib/autosuggest_search.js"

// A fetch whose answers the test releases by hand, in any order. It ignores the abort
// signal on purpose, so the sequence check is proven on its own; the signal is recorded.
function manualFetch() {
  const calls = []
  const fetch = (url, init) => new Promise((resolve, reject) => {
    calls.push({ url, init, resolve, reject })
  })
  const answer = (index, options) => calls[index].resolve({ ok: true, json: async () => ({ options }) })
  return { fetch, calls, answer }
}

// Timers run when the test says so: debounce without waiting.
function manualTimers() {
  const pending = new Map()
  let next = 1
  return {
    setTimer: (fn) => { const id = next++; pending.set(id, fn); return id },
    clearTimer: (id) => { pending.delete(id) },
    flush: () => { const fns = [...pending.values()]; pending.clear(); fns.forEach((fn) => fn()) },
    get size() { return pending.size }
  }
}

function build(overrides = {}) {
  const net = overrides.net || manualFetch()
  const timers = manualTimers()
  const seen = { results: [], errors: [], idle: 0, loading: [] }
  const search = new ServerSearch({
    url: "/org/o1/ticket_lookups?exclude=t1",
    fetch: net.fetch,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    onResults: (options, term) => seen.results.push({ options, term }),
    onError: (error) => seen.errors.push(error),
    onIdle: () => { seen.idle += 1 },
    onLoading: (term) => seen.loading.push(term),
    ...overrides.options
  })
  return { search, net, timers, seen }
}

const tick = () => new Promise((resolve) => setImmediate(resolve))
const A = { value: "id-a", text: "#12 Login bug", detail: "Portal" }
const B = { value: "id-b", text: "#7 Login audit", detail: "Backoffice" }

test("keeps the base URL's parameters and adds the term", () => {
  const params = new URL(searchUrl("/org/o1/ticket_lookups?exclude=t1", "log in"), "http://x.invalid").searchParams

  assert.equal(params.get("exclude"), "t1")
  assert.equal(params.get("q"), "log in")
})

test("drops malformed options instead of rendering them", () => {
  const options = parseOptions({ options: [A, { value: 3, text: "x" }, null, { value: "id-c", text: "C" }] })

  assert.deepEqual(options, [A, { value: "id-c", text: "C", detail: "" }])
  assert.deepEqual(parseOptions({}), [])
  assert.deepEqual(parseOptions(null), [])
})

test("waits for a pause in typing before it asks", () => {
  const { search, net, timers } = build()

  search.input("l")
  search.input("lo")
  search.input("log")
  assert.equal(net.calls.length, 0)
  assert.equal(timers.size, 1)

  timers.flush()
  assert.equal(net.calls.length, 1)
  assert.equal(new URL(net.calls[0].url, "http://x.invalid").searchParams.get("q"), "log")
})

test("drops an answer that arrives after a newer one (reverse order)", async () => {
  const { search, net, timers, seen } = build()

  search.input("lo")
  timers.flush()
  search.input("login")
  timers.flush()
  assert.equal(net.calls.length, 2)
  // The first request was told to stop when the second began.
  assert.equal(net.calls[0].init.signal.aborted, true)

  net.answer(1, [A])
  await tick()
  net.answer(0, [A, B])
  await tick()

  assert.deepEqual(seen.results, [{ options: [A], term: "login" }])
})

test("reports no results as an empty list, not as an error", async () => {
  const { search, net, timers, seen } = build()

  search.input("zzz")
  timers.flush()
  net.answer(0, [])
  await tick()

  assert.deepEqual(seen.results, [{ options: [], term: "zzz" }])
  assert.equal(seen.errors.length, 0)
})

test("reports a network error and searches again afterwards", async () => {
  const { search, net, timers, seen } = build()

  search.input("log")
  timers.flush()
  net.calls[0].reject(new TypeError("Failed to fetch"))
  await tick()
  assert.equal(seen.errors.length, 1)
  assert.equal(seen.results.length, 0)

  search.input("logi")
  timers.flush()
  net.answer(1, [A])
  await tick()
  assert.deepEqual(seen.results, [{ options: [A], term: "logi" }])
})

test("treats an error status as an error, not as results", async () => {
  const { search, net, timers, seen } = build()

  search.input("log")
  timers.flush()
  net.calls[0].resolve({ ok: false, status: 500, json: async () => ({ options: [A] }) })
  await tick()

  assert.equal(seen.errors.length, 1)
  assert.equal(seen.results.length, 0)
})

test("typing after a choice drops the choice, so the field holds a search again", () => {
  const { search } = build()

  search.choose(A)
  assert.deepEqual(search.selection, { value: "id-a", text: "#12 Login bug" })

  search.input("aud")
  assert.deepEqual(search.selection, { value: "", text: "" })
  assert.equal(search.hasSelection, false)
})

test("the choice survives a list that changes under it", async () => {
  const { search, net, timers } = build()

  search.input("login")
  timers.flush()
  net.answer(0, [A, B])
  await tick()
  search.choose(A)

  // The old picker restored the text from the current options; with a server list those
  // are gone or different. The choice is kept apart from them.
  assert.deepEqual(search.selection, { value: "id-a", text: "#12 Login bug" })
})

test("an answer in flight when a choice is made lands nowhere", async () => {
  const { search, net, timers, seen } = build()

  search.input("login")
  timers.flush()
  search.choose(B)
  net.answer(0, [A])
  await tick()

  assert.equal(seen.results.length, 0)
  assert.deepEqual(search.selection, { value: "id-b", text: "#7 Login audit" })
})

test("closing cancels a pending search and aborts the one in flight", async () => {
  const { search, net, timers, seen } = build()

  search.input("log")
  timers.flush()
  search.input("logi")
  search.cancel()
  assert.equal(timers.size, 0)
  assert.equal(net.calls[0].init.signal.aborted, true)

  net.answer(0, [A])
  await tick()
  assert.equal(seen.results.length, 0)
})

test("an aborted request is no error", async () => {
  const { search, net, timers, seen } = build()

  search.input("log")
  timers.flush()
  search.cancel()
  const abort = new Error("The operation was aborted")
  abort.name = "AbortError"
  net.calls[0].reject(abort)
  await tick()

  assert.equal(seen.errors.length, 0)
})

test("an empty term asks nothing and returns to the hint", () => {
  const { search, net, timers, seen } = build()

  search.input("   ")
  timers.flush()

  assert.equal(net.calls.length, 0)
  assert.equal(seen.idle, 1)
})

test("reopening after a 422 keeps the choice the server rendered back", () => {
  // The modal comes back from a refused save with the ticket that was sent; the picker is
  // built from that value and text, not from a list (there is none yet).
  const { search, net } = build({ options: { selection: { value: "id-a", text: "#12 Login bug" } } })

  search.cancel()

  assert.deepEqual(search.selection, { value: "id-a", text: "#12 Login bug" })
  assert.equal(search.hasSelection, true)
  assert.equal(net.calls.length, 0)
})

test("starts without a choice when the server rendered none", () => {
  const { search } = build({ options: { selection: undefined } })

  assert.deepEqual(search.selection, { value: "", text: "" })
})

// Review of #944: the shown results of an older term stayed choosable while the next
// search waited for its debounce and its answer. Typing makes them stale at once.
test("typing makes the shown results stale at once, before the debounce runs out", () => {
  const { search, timers, seen } = build()

  search.input("log")

  assert.deepEqual(seen.loading, ["log"])
  assert.equal(timers.size, 1)
})
