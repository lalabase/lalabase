// What: how many days a hand-typed period covers, as a pure function so
//   node:test can pin it (custom_period_controller.js is six lines over this).
// Why:  the number stands next to the two fields while they are being typed,
//   and it is the reader's only check that they picked the span they meant.
//   "01.06. bis 31.08." is 92 days, not 91: a period INCLUDES both its bounds,
//   which is also how TimeSessionFilterService reads them, and an off-by-one
//   here would quietly disagree with the list below it.

// Returns null when there is nothing to say yet (a bound missing or unparsable),
// so the caller can leave the line blank rather than print "NaN Tage".
// A negative or zero span is returned as it is, NOT clamped: "to before from"
// is an error the caller has to be able to see.
export function dayCount(start, end) {
  if (!start || !end) return null

  const from = Date.parse(`${start}T00:00:00Z`)
  const to = Date.parse(`${end}T00:00:00Z`)
  if (Number.isNaN(from) || Number.isNaN(to)) return null

  return Math.round((to - from) / 86400000) + 1
}
