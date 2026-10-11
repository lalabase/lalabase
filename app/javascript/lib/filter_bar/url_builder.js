// URL building and hidden-field generation for the filter bar

import { escapeAttr } from 'filter_bar/utils'
import { DEFAULT_OPERATOR } from 'filter_bar/change_set'

// The address param of a built-in view. The only built-in views today are the
// knowledge types (?type=note); a second kind of built-in view gets its own
// name here, not a reuse of this one.
export const BUILTIN_VIEW_PARAM = 'type'

/**
 * Build a URL object with all filter, operator, search and SmartFolder params.
 *
 * @param {Object} opts
 * @param {string} opts.baseUrl        - controller urlValue (path)
 * @param {Object} opts.filters        - { category: [values] }
 * @param {Object} opts.operators      - { category: operator }
 * @param {string[]} opts.dropped      - saved categories the reader removed (filter_drop[])
 * @param {string} opts.smartFolderId  - active SF id (optional)
 * @param {string} opts.viewKey        - active built-in view (knowledge type, S7; optional)
 * @param {string} opts.searchValue    - current search string (optional)
 * @param {string} opts.searchMode     - 'content' | 'full' (optional)
 * @param {string[]} opts.carry        - the lane names carried from the current address: the
 *                                       open object and its preview (lib/lane/params, D9 of
 *                                       doc/dateivorschau_plan.md); the controller reads them from
 *                                       the page, this list is the fallback for a page without groups
 * @returns {URL}
 */
export function buildFilterUrl({ baseUrl, filters, operators, dropped = [], smartFolderId, viewKey, searchValue, searchMode, carry = ['ticket_id', 'note_id', 'document_id'] }) {
  const url = new URL(baseUrl, window.location.origin)

  if (smartFolderId) {
    url.searchParams.set('smart_folder_id', smartFolderId)
  } else if (viewKey) {
    url.searchParams.set(BUILTIN_VIEW_PARAM, viewKey)
  }

  // Preserve params from the current address: the open object and its preview (carry)
  const currentParams = new URLSearchParams(window.location.search)
  if (currentParams.has('viewport')) url.searchParams.set('viewport', currentParams.get('viewport'))
  if (currentParams.has('items')) url.searchParams.set('items', currentParams.get('items'))
  carry.forEach((param) => {
    if (currentParams.has(param)) url.searchParams.set(param, currentParams.get(param))
  })
  if (currentParams.has('sort[column]')) url.searchParams.set('sort[column]', currentParams.get('sort[column]'))
  if (currentParams.has('sort[direction]')) url.searchParams.set('sort[direction]', currentParams.get('sort[direction]'))

  if (searchValue) {
    url.searchParams.set('search', searchValue)
  }
  if (searchMode && searchMode !== 'content') {
    url.searchParams.set('search_mode', searchMode)
  }

  appendConditionParams(url.searchParams, filters, operators)

  // Saved categories the reader emptied. Without this the address could not
  // say "without the status condition": no param would mean "as saved".
  ;(dropped || []).forEach(category => url.searchParams.append('filter_drop[]', category))

  return url
}

/**
 * Writes a condition set as filter[cat][] / filter_op[cat] into URLSearchParams
 * or FormData. One place for the rule "the default operator is not written":
 * the address, the save PATCH and the server's reading of both agree on it.
 */
export function appendConditionParams(params, filters, operators) {
  Object.entries(filters || {}).forEach(([category, values]) => {
    if (values && values.length > 0) {
      values.forEach(v => params.append(`filter[${category}][]`, v))
    }
  })
  Object.entries(operators || {}).forEach(([category, op]) => {
    if (op && op !== DEFAULT_OPERATOR && filters[category] && filters[category].length > 0) {
      params.append(`filter_op[${category}]`, op)
    }
  })
  return params
}

/**
 * Build hidden <input> elements for filter + operator params (used in save-modal form).
 */
export function buildFilterHiddenFields(filters, operators) {
  let html = ''
  Object.entries(filters).forEach(([category, values]) => {
    if (values && values.length > 0) {
      values.forEach(v => {
        html += `<input type="hidden" name="filter[${escapeAttr(category)}][]" value="${escapeAttr(v)}">`
      })
    }
  })
  Object.entries(operators).forEach(([category, op]) => {
    if (op && op !== 'or' && filters[category] && filters[category].length > 0) {
      html += `<input type="hidden" name="filter_op[${escapeAttr(category)}]" value="${escapeAttr(op)}">`
    }
  })
  return html
}

/**
 * Build hidden <input> elements for sort params from the current URL.
 */
export function buildSortHiddenFields() {
  const urlParams = new URLSearchParams(window.location.search)
  let html = ''
  const sortColumn = urlParams.get('sort[column]')
  const sortDirection = urlParams.get('sort[direction]')
  if (sortColumn) html += `<input type="hidden" name="sort_column" value="${escapeAttr(sortColumn)}">`
  if (sortDirection) html += `<input type="hidden" name="sort_direction" value="${escapeAttr(sortDirection)}">`
  return html
}
