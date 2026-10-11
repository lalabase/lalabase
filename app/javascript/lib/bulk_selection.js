// What: which bookings the reader has picked for a billing, and what they are.
// Why:  a filter PILL on this page carries turbo_frame "_top", so adjusting a
//   filter is a whole page navigation, not a frame swap. Everything in memory
//   goes with it, and a reader who filtered to find the rest of what they wanted
//   lost what they already had. The panel has to survive that and close only
//   when somebody closes it (user, 31.08.2026).
//
//   The ENTRY is stored, not just the id: a booking filtered off the screen is
//   still in the assignment, and the panel has to keep naming it. Reading the
//   DOM instead would show a shorter list than the one about to be submitted.
//
//   groupId is the billing the booking is ALREADY in, or null. Without it the
//   panel cannot tell that a booking picked out of billing X is being assigned
//   back to billing X: it would list it as "will be taken over" and add its
//   minutes to a total that already contains them.
//
//   Per PATH and in sessionStorage, the same rule as lib/expanded_rows.js: this
//   is one reader's place in one tab, not a preference, and the project list and
//   the organisation-wide list must not inherit each other's selection.

export const STORAGE_PREFIX = "time-list-selection:"

// Per reader AND per path. Without the reader, signing out and in as somebody
// else in the same tab inherited the previous one's selection, and sessionStorage
// outlives a sign-out: the panel would open holding rows they may not even see.
export function storageKey(path, scope = '') {
  return `${STORAGE_PREFIX}${scope}:${path}`
}

// Anything that is not an id mapped to a {duration, label} is dropped rather
// than trusted: this comes back from storage, where a previous version of this
// code, another tab or a curious reader may have left something else.
function sane(entry) {
  return entry && typeof entry === "object" &&
    typeof entry.label === "string" && Number.isFinite(entry.duration) &&
    (entry.groupId === null || typeof entry.groupId === "string")
}

// Every access is guarded. A private window, cleared site data or a browser set
// to refuse storage all throw here, and a forgotten selection is a far smaller
// problem than a list that fails to render.
export function readSelection(storage, path, scope = '') {
  try {
    const raw = storage?.getItem(storageKey(path, scope))
    const parsed = raw ? JSON.parse(raw) : {}
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return new Map()

    return new Map(Object.entries(parsed)
      .filter(([id, entry]) => typeof id === "string" && id.length > 0 && sane(entry))
      .map(([id, entry]) => [id, {
        duration: entry.duration, label: entry.label, groupId: entry.groupId
      }]))
  } catch {
    return new Map()
  }
}

export function writeSelection(storage, path, selection, scope = '') {
  try {
    if (!selection || selection.size === 0) {
      storage?.removeItem(storageKey(path, scope))
      return
    }
    storage?.setItem(storageKey(path, scope), JSON.stringify(Object.fromEntries(selection)))
  } catch {
    // Nothing to do: the selection still works, it just will not outlive the page.
  }
}
