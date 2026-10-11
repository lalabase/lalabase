// "At most one row shows its actions" -- the whole rule, in one place.
//
// This used to be CSS alone: every row carried `group-hover:opacity-100` and
// each one decided for itself. That cannot express "only one", because there is
// nothing that knows about the others. (The rows that stayed lit in Safari,
// several at a time until a resize repainted them, turned out to be a fade that
// Safari never painted over, not a hover chain gone stale: see
// components/hover_reveal.css. The owner below is still the right shape, because
// "only one" has to live somewhere that can see every row.)
//
// Here the rule is a single variable. Two rows cannot both be marked, because
// marking a second one unmarks the first. Nothing depends on the browser
// noticing that a pointer left.
export const REVEALED_CLASS = "is-pointed"
export const ROW_SELECTOR = '[data-hover-reveal-target="row"]'
export const ACTIONS_SELECTOR = '[data-hover-reveal-target="actions"]'

// A row may reveal more than one thing (a date AND an icon strip), so every
// actions node inside the marked row is switched, not just the first.
function applyTo(row, add) {
  if (!row) return

  for (const node of row.querySelectorAll(ACTIONS_SELECTOR)) {
    node.classList[add ? "add" : "remove"](REVEALED_CLASS)
  }
}

export function createRevealTracker() {
  let current = null

  return {
    get current() { return current },

    // Idempotent on purpose: this is called on every pointer move, and the
    // common case is "same row as last time".
    mark(row) {
      if (row === current) return current

      applyTo(current, false)
      applyTo(row, true)
      current = row
      return current
    },
  }
}

// Which row does this event target belong to? Anything outside the list the
// controller is mounted on is "no row" rather than a row of some other list --
// two transcripts on one page must not mark each other's rows.
export function rowFrom(target, root, selector = ROW_SELECTOR) {
  if (!target || typeof target.closest !== "function") return null
  if (!root || typeof root.contains !== "function") return null

  const row = target.closest(selector)
  return row && root.contains(row) ? row : null
}
