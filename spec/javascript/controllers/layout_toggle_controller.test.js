import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { laneParamNames } from '../../../app/javascript/lib/lane/params.js'

const source = readFileSync(new URL('../../../app/javascript/controllers/layout_toggle_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class LayoutToggleController')

function controllerWith(document, { window = {}, groups = null, element = null } = {}) {
  const Controller = runInNewContext(`${source}\nLayoutToggleController`, {
    Controller: class {}, document, window, URL, URLSearchParams,
    sessionStorage: { getItem: () => null },
    CustomEvent: class {
      constructor(type, options) { this.type = type; Object.assign(this, options) }
    },
    readLaneParams: () => groups, laneParamNames
  })
  const controller = new Controller()
  controller.listFilterParamsValue = []
  controller.element = element || { dataset: {}, dispatchEvent: () => {} }
  return controller
}

test('an open dialog or menu owns Escape before the detail lane', () => {
  const overlays = [
    'dialog[open]',
    '[data-neo-inline-popover-target="panel"]:not(.hidden)',
    '[data-dropdown-target="menu"]:not(.hidden)',
    '[data-neo-dropdown-target="menu"]:not(.hidden)',
    // The bulk panel's own layers (tags, people, a select) and its field
    // picker hide with the attribute, not the class.
    '[data-values-layer]:not([hidden])',
    '[data-select-layer]:not([hidden])',
    '[data-ticket-bulk-panel-target="pickerMenu"]:not([hidden])',
    // The "Link" modal of a ticket page is the content of its frame, so it
    // exists only while open. Without it Escape closed the lane BEHIND it.
    '[data-controller~="ticket-relation-modal"]'
  ]

  for (const overlay of overlays) {
    let closed = 0
    let prevented = 0
    const document = { querySelector: (selector) => selector.includes(overlay) ? { overlay } : null }
    const controller = controllerWith(document)
    controller.layoutState = { content: true }
    controller.closeContent = () => { closed += 1 }
    controller.closeOnEscape({ key: 'Escape', defaultPrevented: false, preventDefault: () => { prevented += 1 } })
    assert.equal(closed, 0)
    assert.equal(prevented, 0)
  }

  const controller = controllerWith({ querySelector: () => null })
  assert.equal(controller.escapeBelongsToOverlay({ defaultPrevented: false }), false)
  assert.equal(controller.escapeBelongsToOverlay({ defaultPrevented: true }), true)
})

test('clearing a meeting lane publishes the frame cleanup contract', () => {
  const events = []
  const controller = controllerWith({ querySelector: () => null })
  controller.element = { dispatchEvent: (event) => events.push(event) }
  controller.detailFrameIdValue = 'meeting_display_frame'

  controller.clearDetailFrame()

  assert.equal(events.length, 1)
  assert.equal(events[0].type, 'lane:clear-detail')
  assert.equal(events[0].bubbles, true)
  assert.equal(events[0].detail.frameId, 'meeting_display_frame')
})

test('Escape from a mobile-only detail visits the filter-preserving list', () => {
  const visits = []
  const events = []
  const window = {
    location: {
      href: 'http://lalabase.test/org/o1/projects/p1/meetings/M?meeting_id=M&new=meeting&search=Retro&participant=Anna&viewport=mobile',
      origin: 'http://lalabase.test'
    },
    Turbo: { visit: (url, options) => visits.push([url, options]) },
    history: { pushState: () => assert.fail('mobile close must navigate instead of changing local history') }
  }
  const element = {
    dataset: { indexUrl: '/org/o1/projects/p1/meetings', viewportCurrentModeValue: 'mobile' },
    dispatchEvent: (event) => events.push(event)
  }
  const document = { querySelector: () => null, querySelectorAll: () => [] }
  const groups = { selection: ['meeting_id'], preview: [], form: ['new'], ignore: ['viewport'] }
  const controller = controllerWith(document, { window, groups, element })
  controller.hasLayoutTarget = false
  controller.layoutState = { content: true }
  controller.clearDetailOnCloseValue = true

  controller.closeOnEscape({ key: 'Escape', defaultPrevented: false, preventDefault: () => {} })

  assert.equal(visits.length, 1)
  const target = new URL(visits[0][0])
  assert.equal(target.pathname, '/org/o1/projects/p1/meetings')
  assert.equal(target.searchParams.has('meeting_id'), false)
  assert.equal(target.searchParams.has('new'), false)
  assert.equal(target.searchParams.get('search'), 'Retro')
  assert.equal(target.searchParams.get('participant'), 'Anna')
  assert.equal(target.searchParams.get('viewport'), 'mobile')
  assert.equal(visits[0][1].action, 'advance')
  assert.equal(events.length, 0, 'the outgoing mobile page does not need local frame cleanup')
})

test('desktop close removes selection and creation state while preserving filters', () => {
  const entries = []
  const window = {
    location: { href: 'http://lalabase.test/meetings?new=meeting&meeting_id=M&search=Retro&participant=Anna&viewport=desktop' },
    history: { pushState: (_state, _title, url) => entries.push(url) }
  }
  const groups = { selection: ['meeting_id'], preview: [], form: ['new'] }
  const controller = controllerWith({ querySelectorAll: () => [] }, { window, groups })
  controller.hasLayoutTarget = true
  controller.layoutState = { content: true }
  controller.updateLayout = () => {}

  controller.closeContent()

  const address = new URL(entries[0])
  assert.equal(address.searchParams.has('new'), false)
  assert.equal(address.searchParams.has('meeting_id'), false)
  assert.equal(address.searchParams.get('search'), 'Retro')
  assert.equal(address.searchParams.get('participant'), 'Anna')
  assert.equal(controller.layoutState.content, false)
})

test('filter frame loads keep the open lane and synchronize links and an already open form', () => {
  const current = new URL('http://lalabase.test/meetings?new=meeting&search=Old&participant=Old&page=3&viewport=desktop')
  const events = []
  const control = (tagName, href, fields = []) => ({
    tagName, href, method: 'post', fields,
    getAttribute() { return this.href },
    setAttribute(_name, value) { this.href = value },
    querySelectorAll(selector) {
      const name = selector.match(/name="([^"]+)"/)?.[1]
      return this.fields.filter(field => !name || field.name === name).map(field => ({
        ...field,
        remove: () => { this.fields = this.fields.filter(other => other !== field) }
      }))
    },
    append(input) { this.fields.push(input) }
  })
  const newLink = control('A', '/meetings/new?frame_id=meeting_display_frame&search=Old&participant=Old')
  const editLink = control('A', '/meetings/M/edit.turbo_stream?frame_id=meeting_display_frame&search=Old')
  const form = control('FORM', '/meetings/M.turbo_stream', [{ name: 'participant', value: 'Old' }])
  const createForm = control('FORM', '/meetings.turbo_stream', [{ name: 'search', value: 'Old' }])
  const otherLink = control('A', '/tickets?search=keep')
  const element = {
    dataset: { indexUrl: '/meetings' },
    querySelectorAll: () => [newLink, editLink, form, createForm, otherLink],
    dispatchEvent: event => events.push(event.type)
  }
  const window = {
    location: current,
    history: { state: { lane: true }, replaceState: (_state, _title, url) => { current.href = url } }
  }
  const controller = controllerWith({ createElement: () => ({}) }, { window, element })
  controller.listFilterParamsValue = ['search', 'participant']
  controller.listFrameIdsValue = ['meetings_results']
  controller.layoutState = { content: true }
  controller.hasSelectedRow = () => false
  const frame = {
    id: 'meetings_results',
    src: 'http://lalabase.test/meetings?search=Retro&participant=',
    querySelector: () => ({ dataset: { listFilterQuery: 'search=Retro' } })
  }

  controller.handleFrameLoad({ target: frame })

  assert.equal(current.searchParams.get('search'), 'Retro')
  assert.equal(current.searchParams.has('participant'), false)
  assert.equal(current.searchParams.has('page'), false)
  assert.equal(current.searchParams.get('new'), 'meeting')
  assert.equal(current.searchParams.get('viewport'), 'desktop')
  assert.equal(controller.layoutState.content, true)
  for (const target of [newLink, editLink, form, createForm]) {
    const url = new URL(target.href)
    assert.equal(url.searchParams.get('search'), 'Retro')
    assert.equal(url.searchParams.has('participant'), false)
  }
  assert.equal(new URL(editLink.href).searchParams.get('frame_id'), 'meeting_display_frame')
  assert.equal(form.fields.length, 1)
  assert.equal(form.fields[0].name, 'search')
  assert.equal(form.fields[0].value, 'Retro')
  assert.equal(createForm.fields.length, 1)
  assert.equal(createForm.fields[0].name, 'search')
  assert.equal(createForm.fields[0].value, 'Retro')
  assert.equal(otherLink.href, '/tickets?search=keep')
  assert.deepEqual(events, ['lane:list-changed'])

  frame.src = 'http://lalabase.test/meetings?participant=Anna'
  frame.querySelector = () => ({ dataset: { listFilterQuery: 'participant=Anna' } })
  controller.handleFrameLoad({ target: frame })
  assert.equal(current.searchParams.has('search'), false)
  assert.equal(current.searchParams.get('participant'), 'Anna')
  assert.equal(form.fields.length, 1)
  assert.equal(form.fields[0].name, 'participant')
  assert.equal(form.fields[0].value, 'Anna')
})

test('nested list state replaces removed conditions without touching the selected meeting', () => {
  const current = new URL('http://lalabase.test/meetings?meeting_id=M&filter[participant][]=Old&filter_op[participant]=and&filter_drop[]=creator&page=9')
  const element = { dataset: {}, dispatchEvent: () => {} }
  const window = { location: current, history: { state: { lane: true }, replaceState: (_s, _t, url) => { current.href = url } } }
  const controller = controllerWith({}, { window, element })
  controller.listFilterParamsValue = ['filter', 'filter_op', 'filter_drop', 'sort', 'page']
  controller.syncFilterContext = () => {}
  controller.syncUrlFromFrame({ src: 'http://lalabase.test/meetings?page=9', querySelector: () => ({ dataset: { listFilterQuery: 'filter[creator][]=U&sort[column]=title&sort[direction]=asc&page=2' } }) })
  assert.equal(current.searchParams.get('meeting_id'), 'M')
  assert.equal(current.searchParams.has('filter[participant][]'), false)
  assert.equal(current.searchParams.has('filter_op[participant]'), false)
  assert.equal(current.searchParams.has('filter_drop[]'), false)
  assert.equal(current.searchParams.get('filter[creator][]'), 'U')
  assert.equal(current.searchParams.get('sort[column]'), 'title')
  assert.equal(current.searchParams.get('page'), '2')
})

test('a streamed list replacement synchronizes its clamped page after rendering', async () => {
  const frame = { id: 'meetings_results' }
  const controller = controllerWith({ getElementById: id => id === frame.id ? frame : null })
  controller.listFilterParamsValue = ['page', 'filter']
  controller.listFrameIdsValue = [frame.id]
  const calls = []
  controller.syncUrlFromFrame = value => calls.push(value)
  const event = { target: { getAttribute: () => frame.id }, detail: { render: async () => calls.push('render') } }
  controller.handleListStream(event)
  await event.detail.render({})
  assert.deepEqual(calls, ['render', frame])
})


test('list navigation retains its destination while lane return links inherit current filters', () => {
  const current = new URL('http://lalabase.test/meetings?smart_folder_id=folder-a&page=3&sort[column]=title&sort[direction]=desc&meeting_id=M')
  const link = (href, lane = false) => ({
    tagName: 'A', href,
    getAttribute() { return this.href },
    setAttribute(_name, value) { this.href = value },
    matches() { return lane }
  })
  const destinations = [
    '/meetings?page=4&meeting_id=M',
    '/meetings?sort[column]=title&sort[direction]=asc&meeting_id=M',
    '/meetings?smart_folder_id=folder-b',
    '/meetings',
    '/meetings?items=50'
  ]
  const navigation = destinations.map(href => link(href))
  const back = link('/meetings?smart_folder_id=old', true)
  const detail = link('/meetings/M/edit')
  const element = {
    dataset: { indexUrl: '/meetings' },
    querySelectorAll: () => [...navigation, back, detail]
  }
  const controller = controllerWith({}, { element })
  controller.listFilterParamsValue = ['smart_folder_id', 'page', 'sort', 'items']
  controller.syncFilterContext(current)
  assert.deepEqual(navigation.map(item => item.href), destinations)
  for (const control of [back, detail]) {
    const address = new URL(control.href)
    assert.equal(address.searchParams.get('smart_folder_id'), 'folder-a')
    assert.equal(address.searchParams.get('page'), '3')
    assert.equal(address.searchParams.get('sort[direction]'), 'desc')
    assert.equal(address.searchParams.has('meeting_id'), false)
  }
})
