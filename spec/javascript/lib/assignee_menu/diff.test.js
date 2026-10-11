// The difference the people menu sends: what the ticks say against what the
// menu showed when it opened. Wrong here and the head either sends a request
// for nothing or forgets a person.
import { test } from "node:test"
import assert from "node:assert/strict"
import { assigneeDiff } from "../../../../app/javascript/lib/assignee_menu/diff.js"

test("assigneeDiff is empty when the ticks are what the menu showed", () => {
  assert.deepEqual(assigneeDiff(["a", "b"], ["a", "b"]), { add: [], remove: [] })
  assert.deepEqual(assigneeDiff([], []), { add: [], remove: [] })
  assert.deepEqual(assigneeDiff(undefined, undefined), { add: [], remove: [] })
})

test("assigneeDiff names who got a tick and who lost one, in the menu's order", () => {
  assert.deepEqual(assigneeDiff(["a", "b"], ["b", "c", "d"]), { add: ["c", "d"], remove: ["a"] })
  assert.deepEqual(assigneeDiff([], ["a"]), { add: ["a"], remove: [] })
  assert.deepEqual(assigneeDiff(["a"], []), { add: [], remove: ["a"] })
})

test("assigneeDiff forgets a tick that was set and taken back", () => {
  // Ticked c, unticked c again: the ticks read as they did at the start.
  assert.deepEqual(assigneeDiff(["a"], ["a"]), { add: [], remove: [] })
  // Unticked a, ticked a again.
  assert.deepEqual(assigneeDiff(["a", "b"], ["b", "a"]), { add: [], remove: [] })
})
