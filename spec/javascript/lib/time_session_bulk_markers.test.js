// What: which element a bulk checkbox of the time list belongs to.
// Type: node:test unit spec (no DOM library; small element stubs mimic
//   closest/querySelectorAll).
// Why: these two lookups used to be layout facts -- a <tr> from a table that no
//   longer exists, a .relative anybody may add, and another controller's own
//   data-controller attribute. Nothing could see when a wrapper changed what a
//   checkbox selected. Now the markers are ours and this is where they are read.
import { test } from "node:test"
import assert from "node:assert/strict"
import {
  groupFrom, rowFrom, checkboxesIn, GROUP_SELECTOR, ROW_SELECTOR, CHECKBOX_SELECTOR,
} from "../../../app/javascript/lib/time_session_bulk_markers.js"

// A stub that answers #closest by walking its own parent chain, matching only
// the two markers, and #querySelectorAll by walking its subtree.
function node(markers = [], children = []) {
  const element = {
    markers, children, parent: null,
    closest(selector) {
      let current = element
      while (current) {
        if (current.markers.includes(selector)) return current
        current = current.parent
      }
      return null
    },
    querySelectorAll(selector) {
      const found = []
      const walk = (n) => n.children.forEach((child) => {
        if (child.markers.includes(selector)) found.push(child)
        walk(child)
      })
      walk(element)
      return found
    },
  }
  children.forEach((child) => { child.parent = element })
  return element
}

// The templates write these attributes literally and this module reads them.
// Nothing else connects the two languages, so the literal strings are pinned on
// both sides: here, and in the rendered markup by
// spec/requests/organisations/time_sessions_table_spec.rb.
test("the markers are the attributes the templates write", () => {
  assert.equal(GROUP_SELECTOR, "[data-time-session-bulk-group]")
  assert.equal(ROW_SELECTOR, "[data-time-session-bulk-row]")
  assert.equal(CHECKBOX_SELECTOR, 'input[type="checkbox"][data-time-session-bulk-target="checkbox"]')
})

test("a group checkbox finds the row it stands for", () => {
  const checkbox = node()
  const group = node([GROUP_SELECTOR], [checkbox])

  assert.equal(groupFrom(checkbox), group)
})

// The mutation this exists for: a wrapper added for layout must not become the
// thing a checkbox selects.
test("an extra wrapper without the marker changes nothing", () => {
  const checkbox = node()
  const wrapper = node([], [checkbox])
  const group = node([GROUP_SELECTOR], [wrapper])

  assert.equal(groupFrom(checkbox), group)
})

test("a checkbox outside any group finds nothing rather than the page", () => {
  assert.equal(groupFrom(node()), null)
  assert.equal(rowFrom(node()), null)
})

test("a booking checkbox finds its own booking, not the row above it", () => {
  const checkbox = node()
  const booking = node([ROW_SELECTOR], [checkbox])
  node([GROUP_SELECTOR], [booking])

  assert.equal(rowFrom(checkbox), booking)
})

test("a group hands back every booking checkbox under it, at any depth", () => {
  const first = node([CHECKBOX_SELECTOR])
  const second = node([CHECKBOX_SELECTOR])
  const nested = node([], [second])
  const group = node([GROUP_SELECTOR], [first, nested])

  assert.deepEqual(checkboxesIn(group), [first, second])
})

test("no group means no checkboxes, not a crash", () => {
  assert.deepEqual(checkboxesIn(null), [])
})

// Missing markers used to be silent: closest returned null and toggleGroup
// simply did nothing, which is what happened on the phone, where the bookings
// were a SIBLING of the header rather than inside it.
test("a group whose bookings sit outside it hands back none", () => {
  const stray = node([CHECKBOX_SELECTOR])
  const group = node([GROUP_SELECTOR])
  node([], [group, stray])

  assert.deepEqual(checkboxesIn(group), [])
})
