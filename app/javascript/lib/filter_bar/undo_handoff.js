// The way back after a tab switch (F10, F25). A switch with open changes is
// not blocked: it happens, the change is thrown away, and the message on the
// NEXT page offers "Rückgängig". Because the switch is a full Turbo visit,
// the address to go back to has to cross the navigation; it rides in
// sessionStorage for a few seconds. The storage is injected so node:test can
// pin the rules with a Map.

export const UNDO_KEY = 'lalabase.filterBar.undo'
export const UNDO_MAX_AGE_MS = 15000

export function stashUndo(storage, { url, message, at = Date.now() }) {
  try {
    storage.setItem(UNDO_KEY, JSON.stringify({ url, message, at }))
  } catch (_e) {
    // A blocked storage costs the flash, nothing else.
  }
}

// Takes (and clears) the stashed entry. null when there is none, when it is
// stale, when it points at the page the reader is already on, or when it is
// not a same-site path: the entry is handed to Turbo.visit, so only an
// address of this app ("/...") is a way back. An entry with url null is a
// message without a way back (a deleted view): it is shown, nothing more.
export function takeUndo(storage, { currentUrl, now = Date.now(), maxAgeMs = UNDO_MAX_AGE_MS }) {
  let raw
  try {
    raw = storage.getItem(UNDO_KEY)
    if (raw) storage.removeItem(UNDO_KEY)
  } catch (_e) {
    return null
  }
  if (!raw) return null

  let entry
  try { entry = JSON.parse(raw) } catch (_e) { return null }
  if (!entry || typeof entry.at !== 'number' || typeof entry.message !== 'string') return null
  if (now - entry.at > maxAgeMs) return null
  if (entry.url === null) return entry
  if (typeof entry.url !== 'string' || !/^\/(?!\/)/.test(entry.url)) return null
  if (entry.url === currentUrl) return null
  return entry
}
