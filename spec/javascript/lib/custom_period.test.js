// What: the day count beside the custom period's two date fields
//   (lib/custom_period.js).
// Why:  it is the reader's only check that they typed the span they meant, and
//   it has to agree with the list underneath it. A period INCLUDES both bounds,
//   the way TimeSessionFilterService reads them.
import { test } from "node:test"
import assert from "node:assert/strict"
import { dayCount } from "../../../app/javascript/lib/custom_period.js"

// The example from the design: 01.06. to 31.08.2026 is 92 days.
test("counts both bounds, not the gap between them", () => {
  assert.equal(dayCount("2026-06-01", "2026-08-31"), 92)
})

// n-1 / n / n+1 around the smallest real span, because "inclusive" is exactly
// the kind of rule an off-by-one keeps green.
test("one day is one day, two days is two", () => {
  assert.equal(dayCount("2026-06-01", "2026-06-01"), 1)
  assert.equal(dayCount("2026-06-01", "2026-06-02"), 2)
})

// Across a DST boundary in Europe/Berlin: the hours in the span are not a
// multiple of 24 there, so a naive division truncates and loses a day. Parsed
// as UTC midnights for exactly that reason.
test("survives a daylight-saving change", () => {
  assert.equal(dayCount("2026-03-28", "2026-03-30"), 3)
  assert.equal(dayCount("2026-10-24", "2026-10-26"), 3)
})

// Leap day, the other calendar edge that a hand-rolled month arithmetic misses.
test("counts a leap day", () => {
  assert.equal(dayCount("2028-02-28", "2028-03-01"), 3)
})

test("says nothing while a bound is missing or unreadable", () => {
  assert.equal(dayCount("", "2026-08-31"), null)
  assert.equal(dayCount("2026-06-01", ""), null)
  assert.equal(dayCount(null, null), null)
  assert.equal(dayCount("gestern", "2026-08-31"), null)
})

// NOT clamped: an end before its start has to stay visible as the error it is,
// so the caller can refuse the submit instead of applying a span nobody meant.
test("reports a backwards span rather than hiding it", () => {
  assert.ok(dayCount("2026-08-31", "2026-06-01") < 1)
})
