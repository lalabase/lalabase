// Menu HTML for the filter bar: the category list of "+ Filter" and the value
// menu of one category. Both are floating layers (F29), and both start with
// the same head, built here once: it says which layer this is and it holds the
// ways out, the step back (F36) and the close (F20). Rows are F33, the
// multi-select boxes F11. The operator dropdown carries no colour per
// operator; the word is the signal (F32).

import { escapeHtml, escapeAttr } from 'filter_bar/utils'
import { DEFAULT_OPERATOR } from 'filter_bar/change_set'

const ROW ='w-full text-left px-3 py-1.5 text-xs text-body hover:bg-cream-100 rounded flex items-center gap-2 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ink'
const CHECKBOX = 'h-4 w-4 rounded-sm border-2 border-cream-400 text-ink focus:outline-none focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-0'
const HEAD = 'flex items-center gap-2 px-3 py-2 border-b border-divider'
// The name of the layer, said quietly: it is a label, not a heading of the page.
const HEAD_TITLE = 'text-[10px] font-semibold uppercase tracking-wider text-muted mr-auto'
// F20, the close: no edge and no fill at rest. In a layer the cross is the
// smallest thing in the head, not the loudest.
const HEAD_CLOSE = 'h-6 w-6 -mr-1 flex-none inline-flex items-center justify-center rounded-md text-muted hover:bg-cream-100 hover:text-heading transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-ink'
// F36, one step back: only in a layer that has a step below it.
const HEAD_BACK = 'h-8 w-8 -ml-1 flex-none inline-flex items-center justify-center rounded text-muted hover:text-heading hover:bg-cream-100 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'

/**
 * The head of a floating layer. One builder for both levels: two heads in one
 * bar that drift apart is how a layer stops looking like a layer.
 *
 * The two doors go to different places and can stand together: back is one
 * step (F36), close is out (F20). `extra` takes what belongs to the layer
 * itself, today the operator of a category.
 */
export function buildLayerHead({ title, back = false, extra = '', labels = {} }) {
  const backButton = back
    ? `<button type="button" data-action="click->filter-bar#backToFilterMenu" data-fb-back
               class="${HEAD_BACK}" aria-label="${escapeAttr(labels.back || 'Zurück')}">
        <i class="bi bi-arrow-left text-sm" aria-hidden="true"></i>
      </button>`
    : ''

  return `<div class="${HEAD}" data-fb-head>
      ${backButton}
      <span class="${HEAD_TITLE}">${escapeHtml(title)}</span>
      ${extra}
      <button type="button" data-action="click->filter-bar#closeAllMenus" data-fb-close
              class="${HEAD_CLOSE}" aria-label="${escapeAttr(labels.close_menu || 'Schließen')}">
        <i class="bi bi-x-lg text-[11px]" aria-hidden="true"></i>
      </button>
    </div>`
}

/**
 * Level 1: the categories a condition can be made of. Nothing else: this
 * trigger means "add", and changing the rules of a view is not adding. That
 * door sits in the menu of the active tab (S5).
 *
 * No icon per category: four names would need four distinct signs, and
 * "Status", "Zuständig", "Fällig", "Etikett" do not have them. A category that
 * already carries a condition says so in words at the end of its row, so the
 * reader knows before the click whether they are adding or changing.
 *
 * The list carries role="menu" itself, not the layer around it: the head above
 * it holds a close, and a menu may own nothing but its items.
 */
export function buildCategoryListHtml({ categories, activeFilters = {}, labels = {} }) {
  let items = ''

  categories.forEach(cat => {
    const inUse = (activeFilters[cat.key] || []).length > 0
    items += `<button type="button"
              role="menuitem"
              data-action="click->filter-bar#openValueMenu"
              data-category="${escapeAttr(cat.key)}"
              class="${ROW}">
              <span>${escapeHtml(cat.label)}</span>
              ${inUse ? `<span class="ml-auto text-[10px] text-muted" data-fb-in-use>${escapeHtml(labels.in_use || '')}</span>` : ''}
            </button>`
  })

  return buildLayerHead({ title: labels.add_filter || 'Filter', labels }) +
    `<div role="menu" data-fb-body class="p-1">${items}</div>`
}

/**
 * Level 2: the values of one category as a multi-select. activeFilters and
 * activeOperators are the EFFECTIVE set (saved overridden by the reader), so
 * the boxes show what the pill shows.
 */
export function buildValueMenuHtml({ category, categories, activeFilters, activeOperators, labels, operatorLabels, chipEdit }) {
  const cat = categories.find(c => c.key === category)
  const options = cat ? cat.options : []
  const categoryLabel = cat ? cat.label : category
  const allowedOperators = (cat && cat.allowed_operators) ? cat.allowed_operators : ['or']

  const activeValues = (activeFilters[category] || []).map(String)
  const opLabels = operatorLabels || {}
  const currentOp = activeOperators[category] || DEFAULT_OPERATOR

  let operatorDropdown = ''
  if (allowedOperators.length > 1) {
    const displayOpMap = { or: opLabels.or || 'is', and: opLabels.and || 'is all', not: opLabels.not || 'is not' }
    const displayOp = displayOpMap[currentOp] || displayOpMap.or

    let items = ''
    allowedOperators.forEach(op => {
      const isActive = op === currentOp
      items += `<button type="button"
                data-action="click->filter-bar#setOperator"
                data-operator="${escapeAttr(op)}"
                data-category="${escapeAttr(category)}"
                class="${ROW} ${isActive ? 'font-semibold text-heading' : ''}">
                <span>${escapeHtml(opLabels[op] || op)}</span>
                ${isActive ? '<i class="bi bi-check2 text-xs ml-auto"></i>' : ''}
              </button>`
    })

    operatorDropdown = `
      <div class="relative flex-none" data-filter-bar-target="operatorDropdownContainer">
        <button type="button"
                data-action="click->filter-bar#toggleOperatorDropdown"
                class="flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded text-body hover:bg-cream-100 transition-colors">
          <span>${escapeHtml(displayOp)}</span>
          <i class="bi bi-chevron-down text-[8px] text-muted"></i>
        </button>
        <div data-filter-bar-target="operatorDropdown"
             class="hidden absolute right-0 top-full mt-1 w-36 bg-surface-raised border border-cream-300 rounded-lg shadow-md z-dropdown p-1">
          ${items}
        </div>
      </div>`
  }

  // Opened from "+ Filter" the layer has a step below it, so its head carries
  // the way back (F36) next to the way out (F20). Opened from a pill there is
  // no step below, only the close.
  let html = buildLayerHead({ title: categoryLabel, back: !chipEdit, extra: operatorDropdown, labels })

  // A category that knows why it is empty says so (empty_hint); "no options"
  // alone leaves the reader guessing what is missing.
  if (options.length === 0) {
    const emptyText = (cat && cat.empty_hint) || labels.no_filter_options || 'No options available'
    html += `<div class="px-3 py-3 text-xs text-muted">${escapeHtml(emptyText)}</div>`
  } else {
    html += '<div data-fb-body class="p-1 max-h-64 overflow-y-auto">'
    options.forEach(opt => {
      const isChecked = activeValues.includes(String(opt.value))
      html += `
        <label class="flex items-center gap-3 px-2 py-1.5 text-xs text-body hover:bg-cream-100 rounded cursor-pointer transition-colors">
          <input type="checkbox"
                 ${isChecked ? 'checked' : ''}
                 data-action="change->filter-bar#toggleFilterValue"
                 data-category="${escapeAttr(category)}"
                 data-filter-value="${escapeAttr(String(opt.value))}"
                 class="${CHECKBOX}">
          <span>${escapeHtml(opt.label)}</span>
        </label>
      `
    })
    html += '</div>'
  }

  return html
}
