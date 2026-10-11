// What: which rows of the time list stay open across a reload.
// Type: node:test unit spec (a tiny storage stub; no browser).
// Why:  the bulk assignment answers with a redirect, so without this every row
//   folds away underneath the reader. And every storage access can throw -- a
//   private window, cleared site data, a browser refusing storage -- which must
//   cost a folded row and never the list.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readOpen, isOpen, remember, storageKey, STORAGE_PREFIX } from "../../../app/javascript/lib/expanded_rows.js"

function storage(initial = {}) {
  const data = { ...initial }
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => { data[k] = v },
  }
}

function throwing() {
  return {
    getItem() { throw new DOMException("denied") },
    setItem() { throw new DOMException("denied") },
  }
}

const PATH = "/org/1/time-tracking"

test("nothing remembered means nothing open", () => {
  assert.deepEqual(readOpen(storage(), PATH), [])
  assert.equal(isOpen(storage(), PATH, "a"), false)
})

test("a row that was opened comes back open", () => {
  const s = storage()

  remember(s, PATH, "a|b|c|2026-08-01", true)

  assert.equal(isOpen(s, PATH, "a|b|c|2026-08-01"), true)
})

test("closing a row forgets it, and forgetting twice is harmless", () => {
  const s = storage()
  remember(s, PATH, "row-1", true)

  assert.deepEqual(remember(s, PATH, "row-1", false), [])
  assert.deepEqual(remember(s, PATH, "row-1", false), [])
})

test("opening the same row twice remembers it once", () => {
  const s = storage()

  remember(s, PATH, "row-1", true)

  assert.deepEqual(remember(s, PATH, "row-1", true), ["row-1"])
})

// The project list and the organisation-wide list are two screens.
test("two paths do not inherit each other's open rows", () => {
  const s = storage()

  remember(s, PATH, "row-1", true)

  assert.equal(isOpen(s, "/org/1/projects/9/time-tracking", "row-1"), false)
  assert.equal(storageKey(PATH), `${STORAGE_PREFIX}${PATH}`)
})

test("a storage that throws costs a folded row, not the list", () => {
  assert.deepEqual(readOpen(throwing(), PATH), [])
  assert.equal(isOpen(throwing(), PATH, "row-1"), false)
  assert.doesNotThrow(() => remember(throwing(), PATH, "row-1", true))
})

test("garbage in storage is ignored rather than trusted", () => {
  assert.deepEqual(readOpen(storage({ [storageKey(PATH)]: "not json" }), PATH), [])
  assert.deepEqual(readOpen(storage({ [storageKey(PATH)]: '{"a":1}' }), PATH), [])
  assert.deepEqual(readOpen(storage({ [storageKey(PATH)]: '["ok", 7, null]' }), PATH), ["ok"])
})

test("no key at all changes nothing", () => {
  const s = storage()
  remember(s, PATH, "row-1", true)

  assert.deepEqual(remember(s, PATH, undefined, true), ["row-1"])
  assert.equal(isOpen(s, PATH, undefined), false)
})
