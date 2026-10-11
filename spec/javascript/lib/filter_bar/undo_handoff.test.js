// What: the way back after a tab switch (lib/filter_bar/undo_handoff.js).
// Type: node:test unit spec, storage is a Map.
// Why: the "Rückgängig" in the flash rests on an entry that crosses a Turbo
//   visit through sessionStorage. It must be taken exactly once, must not
//   outlive a few seconds (a stale entry would offer a way back to nowhere),
//   and must not offer the page the reader is already on.
import { test } from "node:test"
import assert from "node:assert/strict"
import { stashUndo, takeUndo, UNDO_KEY, UNDO_MAX_AGE_MS } from "../../../../app/javascript/lib/filter_bar/undo_handoff.js"

const storageWith = () => {
  const map = new Map()
  return {
    setItem: (k, v) => map.set(k, v),
    getItem: k => (map.has(k) ? map.get(k) : null),
    removeItem: k => map.delete(k),
    size: () => map.size
  }
}

test("a stashed entry comes back once, then it is gone", () => {
  const storage = storageWith()
  stashUndo(storage, { url: "/list?smart_folder_id=1&filter[status][]=open", message: "Änderung verworfen", at: 1000 })
  const entry = takeUndo(storage, { currentUrl: "/list?smart_folder_id=2", now: 2000 })
  assert.equal(entry.url, "/list?smart_folder_id=1&filter[status][]=open")
  assert.equal(entry.message, "Änderung verworfen")
  assert.equal(takeUndo(storage, { currentUrl: "/list?smart_folder_id=2", now: 2000 }), null)
  assert.equal(storage.size(), 0)
})

test("a stale entry is dropped (boundary at the max age)", () => {
  const storage = storageWith()
  stashUndo(storage, { url: "/a", message: "m", at: 0 })
  assert.notEqual(takeUndo(storage, { currentUrl: "/b", now: UNDO_MAX_AGE_MS }), null)
  stashUndo(storage, { url: "/a", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/b", now: UNDO_MAX_AGE_MS + 1 }), null)
})

test("an entry pointing at the current page offers no way back", () => {
  const storage = storageWith()
  stashUndo(storage, { url: "/same", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/same", now: 1 }), null)
})

test("garbage in the slot and a throwing storage are both just 'nothing'", () => {
  const storage = storageWith()
  storage.setItem(UNDO_KEY, "{not json")
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }), null)
  const broken = { getItem: () => { throw new Error("blocked") }, setItem: () => { throw new Error("blocked") }, removeItem: () => {} }
  assert.doesNotThrow(() => stashUndo(broken, { url: "/a", message: "m" }))
  assert.equal(takeUndo(broken, { currentUrl: "/x" }), null)
})

test("only a path of this app is a way back; a full or protocol-relative URL is not", () => {
  const storage = storageWith()
  stashUndo(storage, { url: "https://evil.example/list", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }), null)
  stashUndo(storage, { url: "//evil.example/list", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }), null)
  stashUndo(storage, { url: "javascript:alert(1)", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }), null)
  stashUndo(storage, { url: "/list?smart_folder_id=1", message: "m", at: 0 })
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }).url, "/list?smart_folder_id=1")
})

test("a message without a way back (url null) comes back as such, and is still taken once", () => {
  const storage = storageWith()
  stashUndo(storage, { url: null, message: "„Eilig“ gelöscht", at: 0 })
  const entry = takeUndo(storage, { currentUrl: "/list", now: 1 })
  assert.equal(entry.url, null)
  assert.equal(entry.message, "„Eilig“ gelöscht")
  assert.equal(takeUndo(storage, { currentUrl: "/list", now: 1 }), null)
})

test("an entry without a message is nothing, whatever its url", () => {
  const storage = storageWith()
  storage.setItem(UNDO_KEY, JSON.stringify({ url: null, at: 0 }))
  assert.equal(takeUndo(storage, { currentUrl: "/x", now: 1 }), null)
})
