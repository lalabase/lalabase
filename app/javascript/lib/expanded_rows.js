// What: which rows of the time list the reader had open.
// Why:  assigning a selection to a billing answers with a redirect, so the page
//   comes back fresh and every row is folded away again -- including the ones
//   the reader had just opened to decide what to select. Remembering them is the
//   difference between a tool and a nuisance.
//
//   Per PATH, so the project list and the organisation-wide list do not inherit
//   each other's state, and in sessionStorage, because this is one reader's
//   place in one tab, not a preference.
//
//   The row key here is UI state and nothing else: it identifies a position on a
//   screen, never a record. It does not go into a form and it replaces no id.

export const STORAGE_PREFIX = "time-list-open-rows:"

export function storageKey(path) {
  return `${STORAGE_PREFIX}${path}`
}

// Every access is guarded: a private window, cleared site data or a browser set
// to refuse storage all throw here, and a folded row is a far smaller problem
// than a list that fails to render.
export function readOpen(storage, path) {
  try {
    const raw = storage?.getItem(storageKey(path))
    const parsed = raw ? JSON.parse(raw) : []
    return Array.isArray(parsed) ? parsed.filter((key) => typeof key === "string") : []
  } catch {
    return []
  }
}

export function isOpen(storage, path, key) {
  return key ? readOpen(storage, path).includes(key) : false
}

// => the list as it now stands, so a caller can act without reading again.
export function remember(storage, path, key, open) {
  if (!key) return readOpen(storage, path)

  const without = readOpen(storage, path).filter((stored) => stored !== key)
  const next = open ? [...without, key] : without

  try {
    storage?.setItem(storageKey(path), JSON.stringify(next))
  } catch {
    // Nothing to do: the row still opens, it just will not be remembered.
  }
  return next
}
