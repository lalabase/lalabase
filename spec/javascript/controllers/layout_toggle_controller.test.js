import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { laneParamNames } from '../../../app/javascript/lib/lane/params.js'
import { controlIndexPath, indexPaths, withLiveLane } from '../../../app/javascript/lib/lane/filter_context.js'
import { escapeOwned } from '../../../app/javascript/lib/escape_owner.js'

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
    readLaneParams: () => groups, laneParamNames, controlIndexPath, indexPaths, withLiveLane, escapeOwned
  })
  const controller = new Controller()
  controller.listFilterParamsValue = []
  controller.laneContextValue = {}
  controller.unresolvedSelectionValue = {}
  controller.element = element || { dataset: {}, dispatchEvent: () => {} }
  return controller
}

test('a controller that owns Escape keeps the lane open', () => {
  let owns = true
  let closed = 0
  let prevented = 0
  const controller = controllerWith({ querySelector: () => null })
  controller.application = { controllers: [{ ownsEscape: () => owns }, controller] }
  controller.layoutState = { content: true }
  controller.closeContent = () => { closed += 1 }
  const escape = () => ({ key: 'Escape', defaultPrevented: false, preventDefault: () => { prevented += 1 } })

  controller.closeOnEscape(escape())
  assert.equal(closed, 0)
  assert.equal(prevented, 0)

  owns = false
  controller.closeOnEscape(escape())
  assert.equal(closed, 1)
})

test('the owner is asked at keydown, before it can close itself', () => {
  let owns = true
  let closed = 0
  const controller = controllerWith({ querySelector: () => null })
  controller.application = { controllers: [{ ownsEscape: () => owns }] }
  controller.layoutState = { content: true }
  controller.closeContent = () => { closed += 1 }
  const event = { key: 'Escape', defaultPrevented: false, preventDefault: () => {} }

  controller.noteEscapeOwner(event)
  // The owner's own listener runs and closes it before the lane's listener.
  owns = false
  controller.closeOnEscape(event)

  assert.equal(closed, 0)
})

test('an open native dialog, a marked layer or a prevented Escape keep the lane open', () => {
  const page = { querySelector: (selector) => selector.includes('dialog[open]') ? {} : null }
  const controller = controllerWith(page)
  controller.application = { controllers: [] }

  assert.equal(controller.escapeBelongsToOverlay({ defaultPrevented: false }), true)

  const empty = controllerWith({ querySelector: () => null })
  empty.application = { controllers: [] }
  assert.equal(empty.escapeBelongsToOverlay({ defaultPrevented: false }), false)
  assert.equal(empty.escapeBelongsToOverlay({ defaultPrevented: true }), true)
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
    querySelectorAll: selector => selector === '[data-lane-index-url]' ? [] : [newLink, editLink, form, createForm, otherLink],
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
    // A return link answers to the lane return selectors, never to data-lane-keep.
    matches(selector) { return lane && !selector.includes('data-lane-keep') }
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
    querySelectorAll: selector => selector === '[data-lane-index-url]' ? [] : [...navigation, back, detail]
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

// Review of PR #51: the sort heads of the people list are list links that
// keep the lane (data-lane-keep). They were rendered with the person of the
// page request; at click time they take the person open now, or none.
test('a list link marked data-lane-keep takes the live selection and keeps its own list state', () => {
  const link = {
    tagName: 'A', href: '/org/o/people?q=an&sort=last&person_id=A',
    getAttribute() { return this.href },
    setAttribute(_name, value) { this.href = value },
    matches(selector) { return selector === '[data-lane-keep]' }
  }
  const element = {
    dataset: { indexUrl: '/org/o/people' },
    querySelectorAll: selector => selector === '[data-lane-index-url]' ? [] : [link]
  }
  const groups = { selection: ['person_id', 'member_id'], preview: [], form: ['new', 'user_id'], ignore: ['viewport'] }
  const controller = controllerWith({}, { element, groups })
  controller.listFilterParamsValue = ['q', 'kind', 'sort']

  controller.syncFilterContext(new URL('http://lalabase.test/org/o/people?q=an&member_id=M'))
  assert.equal(new URL(link.href).search, '?q=an&sort=last&member_id=M')

  controller.syncFilterContext(new URL('http://lalabase.test/org/o/people?q=an'))
  assert.equal(new URL(link.href).search, '?q=an&sort=last')
})

// "Alle Meetings" shows a project's meeting in its lane (PR 3 of
// doc/meetings_uebersicht_vereinheitlichen_plan.md): its controls live below the
// project's meetings index, which the lane head names. They take the list state
// of the overview; a ticket link in the lane does not.
test('a lane of another list takes the list state on the index its head names', () => {
  const current = new URL('http://lalabase.test/org/o/meetings?search=Neu&meeting_id=M')
  const control = (tagName, href, matched = false) => ({
    tagName, href, method: 'post',
    getAttribute() { return this.href },
    setAttribute(_name, value) { this.href = value },
    matches(selector) { return matched && !selector.includes('data-lane-keep') },
    querySelectorAll: () => [],
    append() {}
  })
  const back = control('A', '/org/o/meetings?search=Alt', true)
  const edit = control('A', '/org/o/projects/p/meetings/M/edit.turbo_stream?list_context=organisation&search=Alt')
  const toggle = control('FORM', '/org/o/projects/p/meetings/M/toggle_search?list_context=organisation&search=Alt')
  const ticket = control('A', '/org/o/projects/p/tickets/T?search=Alt')
  const head = { dataset: { laneIndexUrl: '/org/o/projects/p/meetings' } }
  const element = {
    dataset: { indexUrl: '/org/o/meetings' },
    querySelectorAll: selector => selector === '[data-lane-index-url]' ? [head] : [back, edit, toggle, ticket]
  }
  const controller = controllerWith({ createElement: () => ({}) }, { element })
  controller.listFilterParamsValue = ['search']
  controller.syncFilterContext(current)

  for (const target of [back, edit, toggle]) {
    assert.equal(new URL(target.href).searchParams.get('search'), 'Neu')
  }
  assert.equal(new URL(edit.href).searchParams.get('list_context'), 'organisation')
  assert.equal(ticket.href, '/org/o/projects/p/tickets/T?search=Alt')

  // Without the head the lane's controls belong to no index of this page.
  const stale = control('A', '/org/o/projects/p/meetings/M/edit.turbo_stream?search=Alt')
  controller.element = { dataset: { indexUrl: '/org/o/meetings' }, querySelectorAll: selector => selector === '[data-lane-index-url]' ? [] : [stale] }
  controller.syncFilterContext(current)
  assert.equal(stale.href, '/org/o/projects/p/meetings/M/edit.turbo_stream?search=Alt')
})

test('every request of a lane of another list carries the lane context, also from a link rendered without it', () => {
  const current = new URL('http://lalabase.test/org/o/meetings?search=Neu')
  const inputs = []
  const document = {
    createElement: () => ({ remove() { inputs.splice(inputs.indexOf(this), 1) } })
  }
  const control = (tagName, href) => ({
    tagName, href, method: 'post',
    getAttribute() { return this.href },
    setAttribute(_name, value) { this.href = value },
    matches() { return false },
    querySelectorAll: () => tagName === 'FORM' ? [...inputs] : [],
    append(input) { inputs.push(input) }
  })
  // Rendered by a broadcast or a section refresh, which know no context.
  const refresh = control('A', '/org/o/projects/p/meetings/M/ticket_suggestions')
  const save = control('FORM', '/org/o/projects/p/meetings/M')
  const nextPage = control('A', '/org/o/meetings?page=2')
  const ticket = control('A', '/org/o/projects/p/tickets/T')
  const head = { dataset: { laneIndexUrl: '/org/o/projects/p/meetings' } }
  const element = {
    dataset: { indexUrl: '/org/o/meetings' },
    querySelectorAll: selector => selector === '[data-lane-index-url]' ? [head] : [refresh, save, nextPage, ticket]
  }
  const controller = controllerWith(document, { element })
  controller.listFilterParamsValue = ['search']
  controller.laneContextValue = { list_context: 'organisation' }

  controller.syncFilterContext(current)
  controller.syncFilterContext(current)

  assert.equal(new URL(refresh.href).searchParams.get('list_context'), 'organisation')
  assert.equal(new URL(save.href).searchParams.get('list_context'), 'organisation')
  const contextInputs = inputs.filter(input => input.name === 'list_context')
  assert.equal(contextInputs.length, 1)
  assert.equal(contextInputs[0].value, 'organisation')
  assert.equal(nextPage.href, '/org/o/meetings?page=2')
  assert.equal(ticket.href, '/org/o/projects/p/tickets/T')

  // The project page has no lane context: its lane's links stay as they are.
  const own = control('A', '/org/o/projects/p/meetings/M/ticket_suggestions')
  const projectPage = controllerWith(document, {
    element: { dataset: { indexUrl: '/org/o/projects/p/meetings' }, querySelectorAll: selector => selector === '[data-lane-index-url]' ? [] : [own] }
  })
  projectPage.listFilterParamsValue = ['search']
  projectPage.laneContextValue = {}
  projectPage.syncFilterContext(new URL('http://lalabase.test/org/o/projects/p/meetings'))
  assert.equal(new URL(own.href).searchParams.has('list_context'), false)
})

test('a selection the server did not open leaves the address before anything reads it', () => {
  const current = new URL('http://lalabase.test/org/o/meetings?search=x&meeting_id=GONE&new=meeting')
  const calls = []
  const window = {
    location: current,
    history: {
      state: { lane: true },
      replaceState: (state, _t, url) => { calls.push(state); current.href = url }
    }
  }
  const controller = controllerWith({}, { window })
  controller.unresolvedSelectionValue = { meeting_id: 'GONE', new: 'meeting' }

  controller.dropUnresolvedSelection()

  assert.equal(current.searchParams.has('meeting_id'), false)
  assert.equal(current.searchParams.has('new'), false)
  assert.equal(current.searchParams.get('search'), 'x')
  // The same history entry, its state kept.
  assert.equal(JSON.stringify(calls), JSON.stringify([{ lane: true }]))

  // A selection made since (another value) stays; nothing to drop writes nothing.
  current.href = 'http://lalabase.test/org/o/meetings?meeting_id=OPEN'
  controller.unresolvedSelectionValue = { meeting_id: 'GONE' }
  controller.dropUnresolvedSelection()
  assert.equal(current.searchParams.get('meeting_id'), 'OPEN')
  assert.equal(calls.length, 1)
})

test('closing a lane whose object is gone takes it out of the address in the same entry', () => {
  const current = new URL('http://lalabase.test/org/o/meetings?search=x&meeting_id=M')
  const calls = []
  const window = {
    location: current,
    history: {
      state: { lane: true },
      replaceState: (_s, _t, url) => { calls.push('replace'); current.href = url },
      pushState: () => calls.push('push')
    }
  }
  const controller = controllerWith({}, { window, groups: { selection: ['meeting_id'], preview: [], form: [] } })
  controller.closeContent = options => calls.push(['close', options])
  controller.closeLane()
  assert.equal(current.searchParams.has('meeting_id'), false)
  assert.equal(current.searchParams.get('search'), 'x')
  // The options come from the controller's own realm: compared as JSON.
  assert.equal(JSON.stringify(calls), JSON.stringify(['replace', ['close', { history: false }]]))
})
