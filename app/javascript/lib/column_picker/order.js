// The list model of the column picker (doc/spaltenwahl_plan.md, S2): rows in
// rank order, each with a key and a tick. Pure functions over plain objects so
// node:test can pin them; the controller reads the DOM into this shape and
// writes the result back. No imports on purpose (bare specifiers do not
// resolve under node).

export const REQUIRED = ['number', 'title']

// The same rule as ViewConfiguration.normalize_columns: blanks out,
// duplicates out, the required two first.
export function normalise(keys, required = REQUIRED) {
  const seen = new Set()
  const rest = []
  for (const raw of keys || []) {
    const key = String(raw ?? '').trim()
    if (key === '' || seen.has(key) || required.includes(key)) continue
    seen.add(key)
    rest.push(key)
  }
  return [...required, ...rest]
}

// What the address and the save carry: the required two, then every ticked
// row in list order. Rows are { key, checked }.
export function chosenKeys(rows, required = REQUIRED) {
  return normalise((rows || []).filter(row => row.checked).map(row => row.key), required)
}

// The rows after moving one by `delta` places (negative = up), clamped at the
// ends. A move of zero or of an unknown key returns the same rows.
export function moveRow(rows, key, delta) {
  const from = rows.findIndex(row => row.key === key)
  if (from < 0 || !delta) return rows
  const to = Math.min(rows.length - 1, Math.max(0, from + delta))
  if (to === from) return rows
  const next = rows.slice()
  const [row] = next.splice(from, 1)
  next.splice(to, 0, row)
  return next
}

// A view is dirty when the chosen list differs from the saved one, order
// included: moving a column IS a change, the fit depends on it.
export function isDirty(saved, current) {
  const a = normalise(saved)
  const b = normalise(current)
  return a.length !== b.length || a.some((key, index) => key !== b[index])
}
