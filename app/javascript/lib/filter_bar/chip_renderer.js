// Condition row HTML for the filter bar (doc/filterauswahl_f23_plan.md, S1;
// designer "Filterbearbeitung: Chipzeile überarbeiten", 07.09.2026).
//
// One pill per condition (F13), the values as square tiles inside it (F14),
// the operator as a word between neighbours (F32). Round means "you take hold
// of this", square means "you read this": the pill is the control, the tile
// inside it is a display. No colour codes an operator and nothing carries a
// hard shadow: the word says "und", "oder" or "nicht", and that is the whole
// signal. Rules a saved view cannot dissolve render as read-only pills.
//
// TWO hit areas per pill, divided by a hairline: the left one (name, operator
// word, tiles, chevron) opens the value list, the right one (✕) takes the
// condition away. The chevron belongs in the LEFT zone with the value, or the
// pill would have three targets and one would always be the wrong one.
//
// ⚠️ This reverses F19 / finding 15 of the same morning, which took the cross
// off a value on the argument that a value is removed in the pill's layer, so
// the way is the same at every width. That held for the RESTING row, which is
// a sentence now and has no crosses at all. This is the EDITING row: it exists
// to be changed, and taking one value out of a condition through a layer is
// three clicks for something the reader is already pointing at.

import { escapeHtml, escapeAttr, getOptionsMap } from 'filter_bar/utils'
import { DEFAULT_OPERATOR } from 'filter_bar/change_set'

// 28px, not 36: this row stands permanently above the table, and a control
// that tall reads as a second navigation.
const PILL = 'inline-flex items-stretch h-7 rounded-full border border-cream-300 bg-transparent text-[13px] font-normal text-body whitespace-nowrap overflow-hidden'
// Hover and focus say the same thing: a pill is reached by pointer and by
// keyboard, and it is a control in both cases (F13). focus-within, because the
// elements that take the focus sit inside the pill.
const PILL_EDITABLE = 'group cursor-pointer transition-colors hover:border-ink hover:bg-surface-raised focus-within:border-ink focus-within:bg-surface-raised'
export const PILL_OPEN = ['border-ink', 'bg-cream-200']
// The left zone: everything one reads, plus the chevron that opens the list.
const PILL_BODY = 'inline-flex items-center gap-1.5 px-2.5 py-1 min-w-0'
// The right zone: one errand, take this condition away. A hairline in the
// pill's own border colour divides the two, so a miss on the cross cannot
// open the layer and a miss on the body cannot delete a condition.
const PILL_REMOVE = 'inline-flex items-center justify-center w-[22px] shrink-0 border-l border-cream-300 text-cream-400 ' +
  'hover:text-heading hover:bg-cream-200 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink'
const TILE = 'inline-flex items-center rounded-[5px] px-[7px] py-px bg-cream-200 text-[12.5px] text-body font-normal'
// The cross ON a value, for a condition that holds more than one: taking one
// name out of three is the commonest edit there is.
const TILE_REMOVE = 'inline-flex items-center justify-center w-[22px] -mr-[5px] self-stretch text-cream-400 ' +
  'hover:text-heading transition-colors focus:outline-none focus-visible:ring-1 focus-visible:ring-ink rounded-e-[5px]'
// F32 in text-muted (D6): text-faint reads at about 3,1:1 at 10 px.
const WORD = 'text-[10px] font-medium text-muted'
const CHEVRON = 'bi bi-chevron-down text-[10px] transition-transform'
// The one interactive element of a pill besides the crosses: the chevron
// button opens the layer. The pill itself is not a button (no nesting), a
// click on its body only delegates to the chevron.
const CHEVRON_BUTTON = 'inline-flex items-center justify-center -mr-1 h-6 w-6 rounded text-cream-400 group-hover:text-heading hover:text-heading transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'

function word(text, attr = '') {
  return `<span class="${WORD}" ${attr}>${escapeHtml(text)}</span>`
}

// The one lookup order for a value's name: the category's option label, then
// the server's id-to-name map (users), then the raw value. The save row's
// sentence uses it too, so pill and sentence never name a value differently.
export function labelFor(value, optionsMap, valueLabels) {
  return optionsMap[value] || valueLabels[value] || value
}

/**
 * @param {Object} opts
 * @param {Object}   opts.effective     { filters, operators } as the reader sees them
 * @param {string[]} opts.order         category order
 * @param {Array}    opts.categories    categoriesValue (labels, options)
 * @param {Object}   opts.valueLabels   id => name fallback for user values
 * @param {Object}   opts.labels        labelsValue
 * @param {Object}   opts.connectors    operatorLabelsValue (connector_and/or/not)
 * @param {Function} opts.editable      category => boolean
 * @param {Array}    opts.complexRules  rules the view cannot dissolve
 * @param {?string}  opts.openCategory  the category whose layer stands open
 */
export function buildChipHtml({ effective, order, categories, valueLabels = {}, labels = {}, connectors = {}, editable, complexRules = [], openCategory = null }) {
  const parts = []

  // A condition that is being built has no value yet, and a condition without
  // a value is none. It stands as long as its layer is open (F29), so the
  // layer keeps the element it hangs on and the reader sees what they started.
  const keys = openCategory && !order.includes(openCategory) ? [...order, openCategory] : order

  keys.forEach(category => {
    const values = effective.filters[category] || []
    if (values.length === 0 && category !== openCategory) return
    parts.push(buildConditionPill({
      category, values, operator: effective.operators[category] || DEFAULT_OPERATOR,
      categories, valueLabels, labels, connectors, editable: editable(category)
    }))
  })

  // ⚠️ The joiner rides INSIDE the group of the chip in front of it. Joined
  // between two chips it is a flex item of its own, and on a row that wraps it
  // can end up alone at the start of the next line - a lonely "und" above a
  // condition it does not belong to.
  const and = word(connectors.connector_and || 'und', 'data-joiner')
  let html = parts
    .map((part, index) => `<span class="inline-flex items-center gap-2">${part}${index < parts.length - 1 ? and : ''}</span>`)
    .join('')

  html += buildComplexRules({ complexRules, labels, connectors, valueLabels, leadingJoiner: parts.length > 0 })

  return html
}

function buildConditionPill({ category, values, operator, categories, valueLabels, labels, connectors, editable }) {
  const cat = categories.find(c => c.key === category)
  const categoryLabel = cat ? cat.label : category
  const optionsMap = getOptionsMap(categories, category)

  // One value is taken away with the whole condition (the pill's cross), so it
  // needs no cross of its own; from two upwards each one gets one.
  const removable = editable && values.length > 1
  const tiles = values.map(value => buildTile({
    label: labelFor(value, optionsMap, valueLabels),
    value, category, removable, labels
  }))

  let inner
  if (values.length === 0) {
    // Quiet, and not a value: nothing has been chosen here yet.
    inner = word(labels.nothing_selected || '')
  } else if (cat && cat.flag_labels) {
    // A yes/no category (the waiting states): its one option is named like the
    // category, so the tile says the operator instead, "ja" or "nein".
    const flag = operator === 'not' ? cat.flag_labels.no : cat.flag_labels.yes
    inner = buildTile({ label: flag, value: values[0], category, removable: false, labels })
  } else if (operator === 'not') {
    // "nicht offen und nicht wartet": the exclusion of every value, said as such.
    const notWord = connectors.connector_not || 'nicht'
    const between = word(connectors.connector_and || 'und', 'data-connector') + word(notWord)
    inner = word(notWord) + tiles.join(between)
  } else {
    const between = word(operator === 'and' ? (connectors.connector_and || 'und') : (connectors.connector_or || 'oder'), 'data-connector')
    inner = tiles.join(between)
  }

  const title = editable
    ? (labels.edit_condition || '%{category}').replace('%{category}', categoryLabel)
    : (labels.not_editable_here || '')

  const chevron = editable
    ? `<button type="button"
               class="${CHEVRON_BUTTON}"
               data-fb-open
               data-action="click->filter-bar#openCondition"
               aria-expanded="false"
               aria-haspopup="dialog"
               aria-label="${escapeAttr(title)}">
         <i class="${CHEVRON}" data-chevron aria-hidden="true"></i>
       </button>`
    : ''

  const removeTitle = (labels.remove_condition || '%{category}').replace('%{category}', categoryLabel)
  const remove = editable
    ? `<button type="button"
               class="${PILL_REMOVE}"
               data-fb-remove-condition
               data-action="click->filter-bar#removeCondition"
               data-category="${escapeAttr(category)}"
               title="${escapeAttr(removeTitle)}"
               aria-label="${escapeAttr(removeTitle)}">
         <i class="bi bi-x text-[10px]" aria-hidden="true"></i>
       </button>`
    : ''

  return `<span class="${PILL} ${editable ? PILL_EDITABLE : ''}"
                data-condition="${escapeAttr(category)}"
                title="${escapeAttr(title)}">
      <span class="${PILL_BODY}"
            ${editable ? 'data-action="click->filter-bar#openCondition"' : ''}>
        <span class="text-muted font-normal">${escapeHtml(categoryLabel)}:</span>
        ${inner}
        ${chevron}
      </span>
      ${remove}
    </span>`
}

// A value carries its name and, where a condition holds several, a cross of
// its own. Square: it is read, not taken hold of - the round pill around it is
// the control.
function buildTile({ label, value, category, removable, labels }) {
  if (!removable) return `<span class="${TILE}" data-value-tile>${escapeHtml(label)}</span>`

  const title = (labels.remove_value || '%{value}').replace('%{value}', label)
  return `<span class="${TILE} pr-0" data-value-tile>${escapeHtml(label)}<button type="button"
            class="${TILE_REMOVE}"
            data-action="click->filter-bar#removeValue"
            data-category="${escapeAttr(category)}"
            data-value="${escapeAttr(value)}"
            title="${escapeAttr(title)}"
            aria-label="${escapeAttr(title)}">
      <i class="bi bi-x text-[9px]" aria-hidden="true"></i>
    </button></span>`
}

// Rules the dissolver could not turn into conditions: shown as they are, in
// the same pill so the reader sees them as conditions, without chevron or
// crosses so nobody tries to open them. Between two groups the word is "oder".
function buildComplexRules({ complexRules, labels, connectors, valueLabels, leadingJoiner }) {
  if (!complexRules || complexRules.length === 0) return ''

  const fieldLabels = labels.rule_field_labels || {}
  const operatorLabels = labels.rule_operator_labels || {}
  const and = word(connectors.connector_and || 'und', 'data-joiner')
  const or = word(connectors.connector_or || 'oder', 'data-joiner')
  const hasGroups = new Set(complexRules.map(r => r.group_id)).size > 1

  let html = ''
  let lastGroup = null
  complexRules.forEach((rule, index) => {
    const fieldKey = rule.field.replace(/^custom_/, '')
    const fieldLabel = fieldLabels[rule.field] || fieldLabels[fieldKey] || rule.field
    const opLabel = operatorLabels[rule.operator] || rule.operator
    const valueDisplay = valueLabels[rule.value] || rule.value || ''

    if (index > 0 || leadingJoiner) {
      const useOr = hasGroups && lastGroup !== null && rule.group_id !== lastGroup
      html += useOr ? or : and
    }
    lastGroup = rule.group_id

    html += `<span class="${PILL}" data-complex-rule title="${escapeAttr(labels.not_editable_here || '')}">
        <span class="text-muted font-normal">${escapeHtml(fieldLabel)}:</span>
        <span>${escapeHtml(opLabel)} „${escapeHtml(valueDisplay)}“</span>
      </span>`
  })
  return html
}
