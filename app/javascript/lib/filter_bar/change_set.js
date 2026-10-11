// The state model of the filter bar (doc/filterleiste_s1_s4_plan.md, "The model").
//
//   saved      the view as stored (the dissolver's output), never mutated
//   adHoc      the reader's edits, complete per category, from the address
//   dropped    saved categories the reader removed (filter_drop[] in the address)
//   effective  what the pills show and what the server applies
//
// Pure functions over plain objects so node:test can pin them: nothing here
// touches the DOM, Stimulus or the address bar. A condition set is
// { filters: { category: [values] }, operators: { category: 'or'|'and'|'not' } }.

export const DEFAULT_OPERATOR = 'or'

// A scalar (filter[status]=open from an old bookmark) counts as one value
// instead of throwing inside the value callback and taking the bar with it.
function cleanValues(values) {
  const seen = new Set()
  const out = []
  ;[].concat(values ?? []).forEach(value => {
    const s = String(value)
    if (s === '' || seen.has(s)) return
    seen.add(s)
    out.push(s)
  })
  return out
}

function has(object, key) {
  return Object.prototype.hasOwnProperty.call(object || {}, key)
}

// Drops empty categories, sorts categories and values, defaults the operator.
// Two sets that normalise to the same thing are the same filter: a category
// the reader emptied is no condition, and a value taken away and put back is
// no change.
export function normalise(conditions = {}) {
  const filters = conditions.filters || {}
  const operators = conditions.operators || {}
  const out = { filters: {}, operators: {} }
  Object.keys(filters).sort().forEach(category => {
    const values = cleanValues(filters[category])
    if (values.length === 0) return
    out.filters[category] = values.sort()
    out.operators[category] = operators[category] || DEFAULT_OPERATOR
  })
  return out
}

// Saved categories in their stored order, then the reader's categories in the
// order they were added. Stable across edits, so a pill never jumps.
export function orderedCategories({ saved = {}, adHoc = {} } = {}) {
  const order = []
  Object.keys(saved.filters || {}).forEach(category => { if (!order.includes(category)) order.push(category) })
  Object.keys(adHoc.filters || {}).forEach(category => { if (!order.includes(category)) order.push(category) })
  return order
}

// Per category: the reader's edit if there is one, else the saved condition
// unless the reader dropped it. Categories without values disappear.
export function effectiveConditions({ saved = {}, adHoc = {}, dropped = [] } = {}) {
  const savedFilters = saved.filters || {}
  const savedOperators = saved.operators || {}
  const adHocFilters = adHoc.filters || {}
  const adHocOperators = adHoc.operators || {}
  const droppedSet = new Set(dropped || [])

  const filters = {}
  const operators = {}
  orderedCategories({ saved, adHoc }).forEach(category => {
    let values
    let operator
    if (has(adHocFilters, category)) {
      values = adHocFilters[category]
      operator = adHocOperators[category]
    } else if (droppedSet.has(category)) {
      return
    } else {
      values = savedFilters[category]
      operator = savedOperators[category]
    }
    const clean = cleanValues(values)
    if (clean.length === 0) return
    filters[category] = clean
    operators[category] = operator || DEFAULT_OPERATOR
  })
  return { filters, operators }
}

export function isDirty(saved, effective) {
  return JSON.stringify(normalise(saved)) !== JSON.stringify(normalise(effective))
}

export function conditionCount(effective) {
  return Object.keys(normalise(effective).filters).length
}

// What changed between the stored view and what the reader sees now.
// kind is 'none', 'removed', 'added' or 'changed' (both directions, or an
// operator); removed and added list { category, value } pairs.
export function describeChange(saved, effective) {
  const before = normalise(saved)
  const after = normalise(effective)
  const removed = []
  const added = []
  let operatorChanged = false

  new Set([...Object.keys(before.filters), ...Object.keys(after.filters)]).forEach(category => {
    const was = before.filters[category] || []
    const is = after.filters[category] || []
    was.forEach(value => { if (!is.includes(value)) removed.push({ category, value }) })
    is.forEach(value => { if (!was.includes(value)) added.push({ category, value }) })
    if (was.length && is.length && before.operators[category] !== after.operators[category]) operatorChanged = true
  })

  let kind = 'none'
  if (operatorChanged || (removed.length && added.length)) kind = 'changed'
  else if (removed.length) kind = 'removed'
  else if (added.length) kind = 'added'
  return { kind, removed, added }
}

// The reader changes one category to exactly these values (and operator).
// Returns the next { adHoc, dropped }. Emptying a saved category drops it;
// emptying a category of the reader's own just deletes it. 'or' is the
// default and is not stored, so the address stays short. An edit that lands
// exactly on the saved condition again (a value taken away and put back) is
// no edit and leaves the address: the server reads any filter[] as a change.
export function applyEdit({ saved = {}, adHoc = {}, dropped = [] } = {}, category, values, operator) {
  const filters = { ...(adHoc.filters || {}) }
  const operators = { ...(adHoc.operators || {}) }
  const nextDropped = (dropped || []).filter(c => c !== category)
  const clean = cleanValues(values)

  if (clean.length === 0) {
    delete filters[category]
    delete operators[category]
    if (has(saved.filters || {}, category)) nextDropped.push(category)
  } else if (sameAsSaved(saved, category, clean, operator)) {
    delete filters[category]
    delete operators[category]
  } else {
    filters[category] = clean
    if (operator && operator !== DEFAULT_OPERATOR) operators[category] = operator
    else delete operators[category]
  }
  return { adHoc: { filters, operators }, dropped: nextDropped }
}

function sameAsSaved(saved, category, values, operator) {
  const savedFilters = saved.filters || {}
  if (!has(savedFilters, category)) return false
  const before = normalise({ filters: { [category]: savedFilters[category] }, operators: { [category]: (saved.operators || {})[category] } })
  const after = normalise({ filters: { [category]: values }, operators: { [category]: operator } })
  return JSON.stringify(before) === JSON.stringify(after)
}
