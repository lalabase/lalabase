// The save row (F23) under the condition row. It appears as soon as the
// state differs from the view and has two layers:
//
//   saved view   sentence · Änderung speichern · Als neue Ansicht · Verwerfen
//   base view    N Bedingungen grenzen die Liste ein. · Als Ansicht sichern · Zurücksetzen
//
// Words, not buttons (F4 for the actions, F21 for the one that throws away),
// and no cross: the cross removes a value (F19), it does not discard work.

import { escapeHtml, escapeAttr, getCSRFToken } from 'filter_bar/utils'
import { buildFilterHiddenFields, buildSortHiddenFields } from 'filter_bar/url_builder'

/**
 * Check whether the current filter set contains categories that cannot be
 * converted 1:1 to SmartFolder rules: a date condition with "not". A rule has
 * no NOT form for a date preset, so the converter skips it with a warning
 * (AdHocToSmartFolderService#convert_date, #convert_due_date).
 * "creator" is fully converted since the creator rule field was introduced.
 */
const DATE_CATEGORIES = ['created_at', 'updated_at', 'due_date']

export function hasUnsupportedFilters(filters, operators) {
  for (const [category, values] of Object.entries(filters)) {
    if (!values || values.length === 0) continue
    if (DATE_CATEGORIES.includes(category) && operators[category] === 'not') return true
  }
  return false
}

const ROW = 'flex flex-wrap items-center gap-x-4 gap-y-1 rounded-md border border-amber-500 bg-amber-50 px-3 py-1.5 text-sm text-body mt-1 mb-2'
const ACTION = 'text-sm font-medium text-body underline underline-offset-2 hover:text-heading focus:outline-none focus-visible:ring-1 focus-visible:ring-ink rounded'
const DISCARD = 'text-sm font-medium text-red-700 underline underline-offset-2 hover:text-red-900 focus:outline-none focus-visible:ring-1 focus-visible:ring-red-500 rounded'
const NAME_INPUT = 'h-8 min-w-[14rem] flex-1 max-w-sm px-2 text-sm rounded-md border border-cream-400 bg-surface-raised text-body ' +
  'focus:outline-none focus:border-ink focus:ring-2 focus:ring-ink/10'
const QUIET = 'text-sm font-medium text-muted hover:text-heading focus:outline-none focus-visible:ring-1 focus-visible:ring-ink rounded'

/**
 * Naming a new view happens IN this row, not in a modal (20a, § 9). A modal
 * for one word covers the conditions the name is about, and the name is
 * derived from them anyway: the field opens filled and selected, so the
 * quickest answer is to press Enter.
 *
 * It is a real form with the same hidden fields the modal had, so the server
 * side does not change at all.
 */
export function buildNamingRowHtml({ saveUrl, projectId, filters, operators, suggestion, labels = {}, saveLabels = {}, extraFields = {}, extraHint = null }) {
  const hints = []
  if (hasUnsupportedFilters(filters, operators)) hints.push(saveLabels.save_filter_unsupported_hint || '')
  if (extraHint) hints.push(extraHint)
  const hintHtml = hints.filter(Boolean)
    .map(hint => `<p class="basis-full text-xs text-amber-700">${escapeHtml(hint)}</p>`)
    .join('')

  const hidden = Object.entries(extraFields)
    .filter(([, value]) => value !== null && value !== undefined && value !== '')
    .flatMap(([name, values]) => [].concat(values).map(value => `<input type="hidden" name="${escapeAttr(name)}" value="${escapeAttr(value)}">`))
    .join('')

  return `<form class="${ROW}" method="post" action="${escapeAttr(saveUrl)}" data-turbo="false" data-fb-naming>
      <input type="hidden" name="authenticity_token" value="${escapeAttr(getCSRFToken())}">
      ${projectId ? `<input type="hidden" name="project_id" value="${escapeAttr(projectId)}">` : ''}
      ${buildFilterHiddenFields(filters, operators)}
      ${buildSortHiddenFields()}
      ${hidden}
      <label class="text-body" for="filter-bar-view-name">${escapeHtml(labels.name_of_view || 'Name der Ansicht')}</label>
      <input type="text" id="filter-bar-view-name" name="smart_folder_name" required autocomplete="off"
             value="${escapeAttr(suggestion || '')}" class="${NAME_INPUT}">
      <button type="submit" class="${ACTION}">${escapeHtml(labels.name_save || 'Sichern')}</button>
      <button type="button" data-action="click->filter-bar#cancelNaming" class="${QUIET}">${escapeHtml(labels.name_cancel || 'Abbrechen')}</button>
      ${hintHtml}
    </form>`
}

function action(label, method, classes = ACTION) {
  return `<button type="button" data-action="click->filter-bar#${method}" class="${classes}">${escapeHtml(label)}</button>`
}

/**
 * @param {Object} opts
 * @param {'saved'|'base'} opts.layer
 * @param {string}  opts.sentence   what changed, or how many conditions there are
 * @param {Object}  opts.labels
 * @param {boolean} opts.canSave    the view takes the change (dissolvable, update url known)
 * @param {boolean} opts.canCreate  a new view can be made from the effective set
 * @param {string}  opts.saveState  null | 'error'
 * @param {?number} opts.hits       what the list found under this state
 */
export function buildSaveRowHtml({ layer, sentence, labels = {}, canSave = false, canCreate = false, saveState = null, hits = null }) {
  const actions = []

  if (layer === 'saved') {
    if (saveState === 'error') actions.push(action(labels.retry || 'Erneut versuchen', 'saveChanges'))
    else if (canSave) actions.push(action(labels.save_changes || 'Änderung speichern', 'saveChanges'))
    if (canCreate) actions.push(action(labels.save_as_new_view || 'Als neue Ansicht', 'openSaveModal'))
    actions.push(action(labels.discard || 'Verwerfen', 'discardChanges', DISCARD))
  } else {
    if (canCreate) actions.push(action(labels.save_as_view || 'Als Ansicht sichern', 'openSaveModal'))
    actions.push(action(labels.reset || 'Zurücksetzen', 'resetConditions', DISCARD))
  }

  // What the change did to the list, next to what the change was (20a, § 8).
  // Two different questions, so two pieces: F23 says this row NAMES the change
  // and does not count it, and the count here is of the results, not of the
  // conditions. It costs nothing: the list already counted them for its pager
  // and the bar reads the number out of the reloaded frame.
  const count = (hits === null || hits === undefined)
    ? ''
    : `<span class="font-mono text-xs text-muted" data-fb-hits>${escapeHtml(String(hits))}</span>`

  // No role="status" here: the live region is the persistent target in the
  // component template, so assistive tech sees the sentence change in place.
  // Everything stands in reading order, left: the sentence, what it found, and
  // then the decisions. Pushed apart (mr-auto) the eye reads on the left and
  // has to act on the right, with a hand's width of nothing in between.
  return `<div class="${ROW}">
      <span data-fb-sentence>${escapeHtml(sentence)}</span>
      ${count}
      ${actions.join('')}
    </div>`
}
