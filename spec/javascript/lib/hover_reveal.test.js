// What: the "at most one row shows its actions" rule.
// Type: node:test unit spec (no DOM library; small element stubs mimic
//   classList/querySelectorAll/closest/contains).
// Why: this rule used to be spread over nine CSS class strings, where nothing
//   could hold it and no test could see it. It is the whole reason the tracker
//   exists, so it is the thing pinned here.
import { test } from "node:test"
import assert from "node:assert/strict"
import {
  createRevealTracker, rowFrom, REVEALED_CLASS, ROW_SELECTOR,
} from "../../../app/javascript/lib/hover_reveal.js"

function actions() {
  const classes = new Set()
  return {
    classes,
    classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) },
    get revealed() { return classes.has(REVEALED_CLASS) },
  }
}

function row(nodes = [actions()]) {
  return { nodes, querySelectorAll: () => nodes }
}

test("marking a row reveals its actions", () => {
  const a = actions()
  const tracker = createRevealTracker()

  tracker.mark(row([a]))

  assert.equal(a.revealed, true)
})

test("marking a second row unmarks the first: never two at once", () => {
  const first = actions()
  const second = actions()
  const tracker = createRevealTracker()

  tracker.mark(row([first]))
  tracker.mark(row([second]))

  assert.equal(first.revealed, false)
  assert.equal(second.revealed, true)
})

test("a row that reveals several nodes switches all of them", () => {
  const date = actions()
  const icons = actions()
  const tracker = createRevealTracker()

  tracker.mark(row([date, icons]))
  assert.deepEqual([date.revealed, icons.revealed], [true, true])

  tracker.mark(null)
  assert.deepEqual([date.revealed, icons.revealed], [false, false])
})

test("marking null clears the current row", () => {
  const a = actions()
  const tracker = createRevealTracker()

  tracker.mark(row([a]))
  tracker.mark(null)

  assert.equal(a.revealed, false)
  assert.equal(tracker.current, null)
})

test("re-marking the same row does not touch the classes again", () => {
  let calls = 0
  const node = actions()
  const counting = row([node])
  counting.querySelectorAll = () => { calls++; return [node] }
  const tracker = createRevealTracker()

  tracker.mark(counting)
  const afterFirst = calls
  tracker.mark(counting)

  assert.equal(calls, afterFirst, "the common pointermove case must be free")
})

// rowFrom is the other half: it decides WHICH row an event belongs to.
function target(found) {
  return { closest: (selector) => (selector === ROW_SELECTOR ? found : null) }
}

test("rowFrom finds the row the event happened in", () => {
  const found = row()
  const root = { contains: () => true }

  assert.equal(rowFrom(target(found), root), found)
})

test("rowFrom ignores a row belonging to another list on the same page", () => {
  const root = { contains: () => false }

  assert.equal(rowFrom(target(row()), root), null)
})

test("rowFrom returns null off the rows (gaps, padding, the list itself)", () => {
  const root = { contains: () => true }

  assert.equal(rowFrom(target(null), root), null)
})

test("rowFrom tolerates a target that is not an element", () => {
  const root = { contains: () => true }

  assert.equal(rowFrom(null, root), null)
  assert.equal(rowFrom({}, root), null)
  assert.equal(rowFrom(target(row()), null), null)
})
