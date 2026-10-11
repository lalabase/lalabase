// What: keeping a billing selection across a whole-page navigation.
// Type: node:test unit spec.
// Why:  a filter pill on the time list carries turbo_frame "_top", so adjusting
//   a filter reloads the page and takes everything in memory with it. The entry
//   is stored, not just the id, because a booking filtered off the screen is
//   still in the assignment and the panel still has to name it.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readSelection, writeSelection, storageKey } from "../../../app/javascript/lib/bulk_selection.js"

const fakeStorage = () => {
  const data = new Map()
  return {
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, v),
    removeItem: (k) => data.delete(k),
    _raw: data
  }
}

// groupId is the billing the booking is ALREADY in, or null. Without it the
// panel cannot tell that a booking picked out of billing X is being handed back
// to billing X, and would count its minutes into a total that holds them.
const entry = (duration, label, groupId = null) => ({ duration, label, groupId })

test("a written selection comes back with its durations, names and billings", () => {
  const storage = fakeStorage()
  const selection = new Map([
    ["a", entry(22, "Reproduktion und Fix")],
    ["b", entry(45, "Schon zugeordnet", "billing-1")]
  ])

  writeSelection(storage, "/times", selection)

  assert.deepEqual(readSelection(storage, "/times"), selection)
})

test("keeps two paths apart, so two lists do not inherit each other", () => {
  const storage = fakeStorage()

  writeSelection(storage, "/org/times", new Map([["a", entry(30, "Eins")]]))
  writeSelection(storage, "/project/times", new Map([["b", entry(45, "Zwei")]]))

  assert.deepEqual([...readSelection(storage, "/org/times").keys()], ["a"])
  assert.deepEqual([...readSelection(storage, "/project/times").keys()], ["b"])
})

// Emptying is a removal, not an empty object: a stale key would otherwise sit in
// storage for every list the reader has ever opened.
test("an empty selection takes its key out of storage", () => {
  const storage = fakeStorage()
  writeSelection(storage, "/times", new Map([["a", entry(30, "Eins")]]))

  writeSelection(storage, "/times", new Map())

  assert.equal(storage.getItem(storageKey("/times")), null)
  assert.equal(readSelection(storage, "/times").size, 0)
})

test("reads nothing back from a path that was never written", () => {
  assert.equal(readSelection(fakeStorage(), "/times").size, 0)
})

// This comes back from storage, where an older version of the code or another
// tab may have left something else.
test("drops entries that are not an id mapped to a duration, a name and a billing", () => {
  const storage = fakeStorage()
  storage.setItem(storageKey("/times"), JSON.stringify({
    good: { duration: 30, label: "Eins", groupId: null },
    goodInBilling: { duration: 30, label: "Zwei", groupId: "billing-1" },
    noDuration: { label: "Drei", groupId: null },
    textDuration: { duration: "30", label: "Vier", groupId: null },
    noLabel: { duration: 30, groupId: null },
    // Written by the version before billings were tracked: undefined is not null.
    noGroupId: { duration: 30, label: "Fuenf" },
    numberGroupId: { duration: 30, label: "Sechs", groupId: 7 },
    notAnObject: "Sieben",
    "": { duration: 30, label: "Acht", groupId: null }
  }))

  assert.deepEqual([...readSelection(storage, "/times").keys()], ["good", "goodInBilling"])
})

test("survives a storage that throws on every access", () => {
  const hostile = {
    getItem() { throw new Error("blocked") },
    setItem() { throw new Error("blocked") },
    removeItem() { throw new Error("blocked") }
  }

  assert.equal(readSelection(hostile, "/times").size, 0)
  assert.doesNotThrow(() => writeSelection(hostile, "/times", new Map([["a", entry(30, "Eins")]])))
})

test("survives a missing storage and malformed JSON", () => {
  const storage = fakeStorage()
  storage.setItem(storageKey("/times"), "{nope")

  assert.equal(readSelection(null, "/times").size, 0)
  assert.equal(readSelection(storage, "/times").size, 0)
})

// sessionStorage outlives a sign-out in the same tab. Without the reader in the
// key, signing in as somebody else inherited the previous one's selection, and
// the panel would open holding rows they may not even be allowed to see.
test("files a selection under the reader, not only the path", () => {
  const storage = fakeStorage()

  writeSelection(storage, "/times", new Map([["a", entry(30, "Meins")]]), "user-1")

  assert.equal(readSelection(storage, "/times", "user-1").size, 1)
  assert.equal(readSelection(storage, "/times", "user-2").size, 0)
})

test("emptying one reader's selection leaves the other's alone", () => {
  const storage = fakeStorage()
  writeSelection(storage, "/times", new Map([["a", entry(30, "Eins")]]), "user-1")
  writeSelection(storage, "/times", new Map([["b", entry(45, "Zwei")]]), "user-2")

  writeSelection(storage, "/times", new Map(), "user-1")

  assert.equal(readSelection(storage, "/times", "user-1").size, 0)
  assert.equal(readSelection(storage, "/times", "user-2").size, 1)
})
