// What: the fit rule of the column picker (lib/column_picker/fit.js).
// Type: node:test unit spec, no DOM.
// Why: the boundary line in the panel and the data-fit on the table both come
//   from this count. Off by one and the wrong column drops under the title,
//   or the panel draws the line where the table does not break.
import { test } from "node:test"
import assert from "node:assert/strict"
import { availableWidth, fitCount, fullModeWidth } from "../../../../app/javascript/lib/column_picker/fit.js"

test("availableWidth takes only the fixed columns off the list width, never below zero", () => {
  assert.equal(availableWidth(1000, 260), 740)
  assert.equal(availableWidth(200, 260), 0)
  assert.equal(availableWidth(undefined, 260), 0)
  assert.equal(availableWidth(500, 260), 240)
})

test("fitCount counts the leading widths that fit, in order, as n-1 / n / n+1", () => {
  const mins = [120, 110, 140]
  assert.equal(fitCount(229, mins), 1) // one short of the second
  assert.equal(fitCount(230, mins), 2) // exactly the second
  assert.equal(fitCount(231, mins), 2) // one more changes nothing until the third fits
  assert.equal(fitCount(370, mins), 3)
})

test("fitCount never skips a rank: a narrow third column does not squeeze in before a wide second", () => {
  assert.equal(fitCount(200, [120, 140, 60]), 1)
})

test("fitCount is zero without room and full without columns", () => {
  assert.equal(fitCount(0, [100]), 0)
  assert.equal(fitCount(500, []), 0)
  assert.equal(fitCount(500, undefined), 0)
})

test("fullModeWidth is the share of the table, never under the minimum: n-1 / n / n+1 at the crossing", () => {
  // 14% of the table meets a 138px minimum at a table of 985.71px.
  assert.equal(fullModeWidth(138, 0.14, 900), 138) // share 126 is short, the minimum holds
  assert.equal(fullModeWidth(138, 0.14, 986), 138) // share rounds to 138 exactly
  assert.equal(fullModeWidth(138, 0.14, 1000), 140) // the share wins
  assert.equal(fullModeWidth(0, 0.1, 500), 50)
  assert.equal(fullModeWidth(100, undefined, undefined), 100)
})
