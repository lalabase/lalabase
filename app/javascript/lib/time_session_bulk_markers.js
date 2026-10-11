// What: which element a bulk checkbox of the time list belongs to.
// Why:  the selectors used to be layout facts. The group was found with
//   `closest('tr') || closest('.relative')` and the row with
//   `closest('[data-controller="time-session-row"]')` -- a table that no longer
//   exists, a positioning class anybody may add, and a foreign controller's own
//   attribute. A new wrapper silently changed what a checkbox selected, and on
//   the phone the group checkbox found nothing at all, because the cards were a
//   SIBLING of the header rather than inside it.
//
//   Markers of our own, and one module that owns them, so the rule can be read
//   and tested without a browser.

export const GROUP_SELECTOR = "[data-time-session-bulk-group]"
export const ROW_SELECTOR = "[data-time-session-bulk-row]"
export const CHECKBOX_SELECTOR = 'input[type="checkbox"][data-time-session-bulk-target="checkbox"]'

// The row (a subject in a month) a group checkbox stands for, or null.
export function groupFrom(element) {
  return element?.closest?.(GROUP_SELECTOR) ?? null
}

// The single booking a checkbox sits in, or null. This is the element that
// carries the selection tint.
export function rowFrom(element) {
  return element?.closest?.(ROW_SELECTOR) ?? null
}

// Every booking checkbox inside one group, disabled ones included: the caller
// decides what to do with those, this module only answers "which".
export function checkboxesIn(group) {
  return group ? Array.from(group.querySelectorAll(CHECKBOX_SELECTOR)) : []
}
