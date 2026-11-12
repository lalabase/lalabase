// What: which section the page outline marks as "here" (lib/page_outline.js).
// Why:  the plain rule, "the last section above the reading line", is wrong at
//   both ends of a page: at the bottom the last sections never reach the line,
//   and a jump to one of them has to mark the section that was chosen.
import { test } from "node:test"
import assert from "node:assert/strict"
import { currentSection } from "../../../app/javascript/lib/page_outline.js"

const line = 120

test("a page without sections has no current one", () => {
  assert.equal(currentSection({ tops: [], line }), -1)
})

test("at the top of the page the first section is current, though it has not reached the line", () => {
  assert.equal(currentSection({ tops: [180, 600, 1100], line }), 0)
})

test("the last section whose top has passed the line is current", () => {
  assert.equal(currentSection({ tops: [-400, 20, 520], line }), 1)
  assert.equal(currentSection({ tops: [-900, -480, 119], line }), 2)
})

test("a section exactly on the line counts as reached, one pixel below does not", () => {
  assert.equal(currentSection({ tops: [-300, 120], line }), 1)
  assert.equal(currentSection({ tops: [-300, 121], line }), 0)
})

test("at the end of the page the last section is current, however far from the line", () => {
  assert.equal(currentSection({ tops: [-700, 200, 430], line, atEnd: true }), 2)
})

test("a chosen section stays current while it is in the window, even at the end of the page", () => {
  assert.equal(currentSection({ tops: [-700, 200, 430], line, atEnd: true, chosen: 1, height: 800 }), 1)
})

test("a chosen section that left the window gives way to the measured one", () => {
  assert.equal(currentSection({ tops: [-700, -300, 60], line, chosen: 0, height: 800 }), 2)
  assert.equal(currentSection({ tops: [40, 500, 900], line, chosen: 2, height: 800 }), 0)
})

test("a choice outside the list is ignored", () => {
  assert.equal(currentSection({ tops: [-10, 300], line, chosen: 5, height: 800 }), 0)
  assert.equal(currentSection({ tops: [-10, 300], line, chosen: -1, height: 800 }), 0)
})
