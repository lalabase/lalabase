import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { redrawAddress } from '../../../app/javascript/lib/inbox_live.js'

// The bulk bar of the inbox. Without ids the routes behind its two forms act
// on EVERY notification, so a submit with nothing ticked must never leave:
// the buttons are disabled, and the submit itself is stopped, because Turbo
// re-enables a submitter after a failed request.

const source = readFileSync(new URL('../../../app/javascript/controllers/inbox_bulk_select_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class InboxBulkSelectController')

function classList(initial = []) {
  const set = new Set(initial)
  return {
    toggle(name, force) { if (force) set.add(name); else set.delete(name) },
    has(name) { return set.has(name) }
  }
}

function fakeForm() {
  const button = { disabled: false }
  const inputs = []
  return {
    button,
    inputs,
    querySelectorAll(selector) { return selector.startsWith('button') ? [button] : inputs.splice(0) },
    appendChild(input) { inputs.push(input) }
  }
}

// organisations: { id: [organisationId, organisationName] }, the inbox above the
// organisations, where a row names its organisation. list: the dataset of the
// list element (the pages the endless scroll has loaded).
function build({ ids = ['n1', 'n2'], organisations = {}, address = 'https://lalabase.test/inbox', lang = 'de', list = null } = {}) {
  const document = {
    activeElement: null,
    documentElement: { lang },
    createElement: () => ({ dataset: {}, remove() {} }),
    getElementById: (id) => (id === 'inbox_master_list' && list ? { dataset: list } : null)
  }
  const window = { location: { href: address, origin: new URL(address).origin } }
  const Controller = runInNewContext(`${source}\nInboxBulkSelectController`,
    { Controller: class {}, document, window, URL, Intl, redrawAddress })
  const controller = new Controller()
  const forms = [fakeForm(), fakeForm()]
  const checkboxes = ids.map((id) => {
    const [organisationId, organisationName] = organisations[id] || []
    return { checked: false, dataset: { notificationId: id, organisationId, organisationName }, focus() { this.focused = true } }
  })
  const bar = { classList: classList(['hidden']), contains: (node) => node === 'inside-the-bar' }
  controller.element = { classList: classList(), querySelector: () => null }
  controller.formTargets = forms
  controller.checkboxTargets = checkboxes
  controller.rowTargets = checkboxes.map((cb) => ({ dataset: cb.dataset, classList: classList() }))
  controller.hasBarTarget = true
  controller.barTarget = bar
  controller.hasCountTarget = true
  controller.countTarget = { textContent: '' }
  controller.connect()
  return { controller, forms, checkboxes, bar, document }
}

test('"Auswählen" opens the bar with every action disabled and focuses the first checkbox', () => {
  const { controller, forms, checkboxes, bar } = build()
  let closed = false
  controller.startSelecting({ target: { closest: () => ({ removeAttribute: () => { closed = true } }) } })

  assert.equal(closed, true)
  assert.equal(bar.classList.has('hidden'), false)
  assert.equal(controller.element.classList.has('inbox-selecting'), true)
  assert.equal(controller.countTarget.textContent, 0)
  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(checkboxes[0].focused, true)
})

test('a submit with nothing ticked is stopped, one with a tick leaves with its ids', () => {
  const { controller, forms, checkboxes } = build()
  let prevented = 0
  const submit = { preventDefault: () => { prevented += 1 } }

  controller.startSelecting()
  controller.guardSubmit(submit)
  assert.equal(prevented, 1)

  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })
  controller.guardSubmit(submit)
  assert.equal(prevented, 1)
  assert.ok(forms.every((form) => !form.button.disabled))
  assert.deepEqual(forms[0].inputs.map((input) => [input.name, input.value]), [['ids[]', 'n1']])
})

test('a failed submit redraws the buttons from the selection instead of leaving them as Turbo left them', () => {
  const { controller, forms, checkboxes } = build()
  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })
  checkboxes[0].checked = false
  controller.toggle({ target: checkboxes[0] }) // unticked while the request was pending
  forms.forEach((form) => { form.button.disabled = false }) // Turbo re-enabled the submitter

  controller.onBulkSubmit({ detail: { success: false } })

  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(controller.selectedIdsValue.length, 0)
})

test('a successful submit clears the selection and shuts the bar', () => {
  const { controller, checkboxes, bar } = build()
  controller.selectAll()
  assert.equal(controller.countTarget.textContent, 2)

  controller.onBulkSubmit({ detail: { success: true } })

  assert.equal(controller.selectedIdsValue.length, 0) // an array of the controller's realm, so no deepEqual
  assert.ok(checkboxes.every((cb) => !cb.checked))
  assert.equal(bar.classList.has('hidden'), true)
  assert.equal(controller.element.classList.has('inbox-selecting'), false)
})

test('the way out hands focus back to the "···" trigger when it sat in the bar', () => {
  const { controller, document } = build()
  const trigger = { focus() { this.focused = true } }
  controller.element.querySelector = (selector) => (selector === '.people-head summary.more-menu__trigger' ? trigger : null)
  controller.startSelecting()
  document.activeElement = 'inside-the-bar'

  controller.clear()

  assert.equal(trigger.focused, true)
})

// A stream redraws the list while a selection stands (the delayed mark-read
// of the open ticket does, five seconds after a click). The new rows come
// unticked; the selection used to live on, over rows without a tick and with
// the ids of rows that had left.
const afterRedraw = () => new Promise((resolve) => setTimeout(resolve, 0))

function redraw(controller, ids) {
  const checkboxes = ids.map((id) => ({ checked: false, dataset: { notificationId: id } }))
  controller.checkboxTargets = checkboxes
  controller.rowTargets = checkboxes.map((cb) => ({ dataset: cb.dataset, classList: classList() }))
  checkboxes.forEach(() => controller.checkboxTargetConnected())
  return checkboxes
}

test('a redrawn list ticks the rows that are still selected and drops the ones that left', async () => {
  const { controller, forms } = build({ ids: ['n1', 'n2', 'n3'] })
  controller.selectAll()

  const checkboxes = redraw(controller, ['n2', 'n3', 'n4'])
  await afterRedraw()

  assert.deepEqual(checkboxes.map((cb) => cb.checked), [true, true, false])
  assert.equal(controller.countTarget.textContent, 2)
  assert.deepEqual(forms[0].inputs.map((input) => input.value), ['n2', 'n3'])
  assert.ok(controller.rowTargets[0].classList.has('inbox-row--checked'))
})

test('a redraw that leaves no selected row keeps the mode open with the actions disabled', async () => {
  const { controller, forms, bar } = build({ ids: ['n1'] })
  controller.startSelecting()
  controller.selectAll()

  redraw(controller, ['n9'])
  await afterRedraw()

  assert.equal(controller.selectedIdsValue.length, 0)
  assert.ok(forms.every((form) => form.button.disabled))
  assert.equal(bar.classList.has('hidden'), false) // entered through the menu, left through the way out
})

test('rows added by the endless scroll leave the selection alone', async () => {
  const { controller, checkboxes } = build({ ids: ['n1', 'n2'] })
  checkboxes[0].checked = true
  controller.toggle({ target: checkboxes[0] })

  const more = { checked: false, dataset: { notificationId: 'n3' } }
  controller.checkboxTargets = [...checkboxes, more]
  controller.checkboxTargetConnected()
  await afterRedraw()

  assert.deepEqual(controller.checkboxTargets.map((cb) => cb.checked), [true, false, false])
  assert.equal(controller.countTarget.textContent, 1)
})

test('the rows of the first draw, which connect before the controller does, start nothing', async () => {
  const Controller = runInNewContext(`${source}\nInboxBulkSelectController`, { Controller: class {}, document: {} })
  const controller = new Controller()
  controller.checkboxTargetConnected()
  await afterRedraw()

  assert.equal(controller.reconcilePending, undefined)
})

// The inbox above the organisations (followAddress): the bar lies outside the
// list and outside the frame the search reloads, so the address written into
// its forms can be older than the list. The submit takes the list state from
// the page's address and the pages the endless scroll has loaded, like the
// live redraw does (lib/inbox_live.js).
function submitOf(form, confirm) {
  return { target: form, params: { confirm }, preventDefault() { this.prevented = true } }
}

function tick(controller, checkbox, checked = true) {
  checkbox.checked = checked
  controller.toggle({ target: checkbox })
}

test('above the organisations a submit carries the list state of the address and the loaded pages', () => {
  const { controller, checkboxes } = build({
    address: 'https://lalabase.test/inbox?org=o1&search=Regal&state_filters%5B%5D=unread',
    list: { neoEndlessScrollFirstPageValue: '1', neoEndlessScrollPageValue: '3' }
  })
  controller.followAddressValue = true
  const form = { action: 'https://lalabase.test/inbox/selection/archive?search=Alt', dataset: {} }

  tick(controller, checkboxes[0])
  controller.guardSubmit(submitOf(form))

  const action = new URL(form.action)
  assert.equal(action.pathname, '/inbox/selection/archive')
  assert.equal(action.searchParams.get('search'), 'Regal')
  assert.equal(action.searchParams.get('org'), 'o1')
  assert.deepEqual(action.searchParams.getAll('state_filters[]'), ['unread'])
  assert.equal(action.searchParams.get('page'), '1')
  assert.equal(action.searchParams.get('through_page'), '3')
})

test('inside an organisation the address of the form stays as it was written', () => {
  const { controller, checkboxes } = build({ address: 'https://lalabase.test/org/o1/inbox?search=Regal' })
  const form = { action: 'https://lalabase.test/org/o1/inbox/mark_all_read', dataset: {} }

  tick(controller, checkboxes[0])
  controller.guardSubmit(submitOf(form))

  assert.equal(form.action, 'https://lalabase.test/org/o1/inbox/mark_all_read')
})

test('a submit with nothing ticked is stopped before its address is touched', () => {
  const { controller } = build()
  controller.followAddressValue = true
  const form = { action: 'https://lalabase.test/inbox/selection/archive', dataset: {} }
  const submit = submitOf(form, '{number} / {organisations}')

  controller.startSelecting()
  controller.guardSubmit(submit)

  assert.equal(submit.prevented, true)
  assert.equal(form.action, 'https://lalabase.test/inbox/selection/archive')
  assert.equal(form.dataset.turboConfirm, undefined)
})

// The question before a bulk action that crosses organisations: how many rows,
// and which organisations. Inside one organisation the bar acts at once.
test('a selection within one organisation is not questioned', () => {
  const { controller, checkboxes } = build({ organisations: { n1: ['o1', 'Nordwind GmbH'], n2: ['o1', 'Nordwind GmbH'] } })
  const form = { action: 'https://lalabase.test/inbox/selection/archive', dataset: { turboConfirm: 'left over' } }

  checkboxes.forEach((checkbox) => tick(controller, checkbox))
  controller.guardSubmit(submitOf(form, '{number} Meldungen aus {organisations} archivieren?'))

  assert.equal(form.dataset.turboConfirm, undefined)
})

test('a selection across organisations is questioned with its number and their names', () => {
  const { controller, checkboxes } = build({
    ids: ['n1', 'n2', 'n3'],
    organisations: { n1: ['o1', 'Nordwind GmbH'], n2: ['o2', 'Suedhang AG'], n3: ['o1', 'Nordwind GmbH'] }
  })
  const form = { action: 'https://lalabase.test/inbox/selection/archive', dataset: {} }
  const submit = submitOf(form, '{number} Meldungen aus {organisations} archivieren?')

  checkboxes.forEach((checkbox) => tick(controller, checkbox))
  controller.guardSubmit(submit)

  assert.equal(form.dataset.turboConfirm, '3 Meldungen aus Nordwind GmbH und Suedhang AG archivieren?')
  assert.equal(submit.prevented, undefined)

  tick(controller, checkboxes[1], false)
  controller.guardSubmit(submit)
  assert.equal(form.dataset.turboConfirm, undefined)
})

test('two organisations of the same name are two organisations, named in the language of the page', () => {
  const { controller, checkboxes } = build({
    ids: ['n1', 'n2', 'n3'], lang: 'en',
    organisations: { n1: ['o1', 'Muster GmbH'], n2: ['o2', 'Muster GmbH'], n3: ['o3', 'Beispiel AG'] }
  })
  const form = { action: 'https://lalabase.test/inbox/selection/mark_read', dataset: {} }

  checkboxes.forEach((checkbox) => tick(controller, checkbox))
  controller.guardSubmit(submitOf(form, 'Mark {number} notifications from {organisations} as read?'))

  assert.equal(form.dataset.turboConfirm, 'Mark 3 notifications from Muster GmbH, Muster GmbH, and Beispiel AG as read?')
})

test('rows without an organisation (the inbox of one organisation) are never questioned', () => {
  const { controller, checkboxes } = build()
  const form = { action: 'https://lalabase.test/org/o1/inbox/archive_all', dataset: {} }

  checkboxes.forEach((checkbox) => tick(controller, checkbox))
  controller.guardSubmit(submitOf(form, '{number} / {organisations}'))

  assert.equal(form.dataset.turboConfirm, undefined)
})
