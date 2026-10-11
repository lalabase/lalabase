// What: the list model of the column picker (lib/column_picker/order.js).
// Type: node:test unit spec, no DOM.
// Why: the address (cols[]) and the save row rest on chosenKeys and isDirty;
//   a move by keyboard rests on moveRow. The rule mirrors
//   ViewConfiguration.normalize_columns on the server: what the browser
//   writes, the server reads back to the same list.
import { test } from "node:test"
import assert from "node:assert/strict"
import { normalise, chosenKeys, moveRow, isDirty } from "../../../../app/javascript/lib/column_picker/order.js"

const rows = [
  { key: 'assignees', checked: true },
  { key: 'created_at', checked: false },
  { key: 'tags', checked: true }
]

test("normalise puts number and title first, drops blanks and duplicates", () => {
  assert.deepEqual(normalise(['tags', '', 'title', 'tags', null, 'number']), ['number', 'title', 'tags'])
  assert.deepEqual(normalise([]), ['number', 'title'])
  assert.deepEqual(normalise(undefined), ['number', 'title'])
})

test("chosenKeys is the required two plus the ticked rows in list order", () => {
  assert.deepEqual(chosenKeys(rows), ['number', 'title', 'assignees', 'tags'])
  assert.deepEqual(chosenKeys([]), ['number', 'title'])
})

test("moveRow moves by delta and clamps at both ends", () => {
  assert.deepEqual(moveRow(rows, 'tags', -1).map(r => r.key), ['assignees', 'tags', 'created_at'])
  assert.deepEqual(moveRow(rows, 'tags', -5).map(r => r.key), ['tags', 'assignees', 'created_at'])
  assert.deepEqual(moveRow(rows, 'assignees', 1).map(r => r.key), ['created_at', 'assignees', 'tags'])
  assert.deepEqual(moveRow(rows, 'assignees', 9).map(r => r.key), ['created_at', 'tags', 'assignees'])
})

test("moveRow leaves the rows alone for no delta, an unknown key or a move against the edge", () => {
  assert.equal(moveRow(rows, 'tags', 0), rows)
  assert.equal(moveRow(rows, 'nope', 1), rows)
  assert.equal(moveRow(rows, 'assignees', -1), rows)
})

test("isDirty sees a moved column as a change and an unchanged list as none", () => {
  assert.equal(isDirty(['number', 'title', 'a', 'b'], ['number', 'title', 'a', 'b']), false)
  assert.equal(isDirty(['number', 'title', 'a', 'b'], ['number', 'title', 'b', 'a']), true)
  assert.equal(isDirty(['number', 'title', 'a'], ['number', 'title', 'a', 'b']), true)
  assert.equal(isDirty(['a', 'title'], ['title', 'a', 'number']), false) // normalised alike
})

test('meeting columns have only the configured required title, retaining chosen order', () => {
  assert.deepEqual(normalise(['participants', 'title', 'creator', 'participants'], ['title']), ['title', 'participants', 'creator'])
  assert.deepEqual(chosenKeys([{ key: 'occurred_at', checked: true }, { key: 'participants', checked: false }], ['title']), ['title', 'occurred_at'])
})
