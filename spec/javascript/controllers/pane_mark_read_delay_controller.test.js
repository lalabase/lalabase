import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { setImmediate } from 'node:timers/promises'
import { listActionAddress } from '../../../app/javascript/lib/inbox_live.js'

// The delayed mark-as-read gives the reader a few seconds for a look. It
// counts only while the ticket is still in view: a lane shut in place hides
// it by a class on the grid and leaves this controller connected.

const source = readFileSync(new URL('../../../app/javascript/controllers/pane_mark_read_delay_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class PaneMarkReadDelayController')

function build({ laneShut, followAddress = false, pageAddress = 'https://lalabase.test/inbox', deferred = false }) {
  const requests = []
  const rendered = []
  const warned = []
  const list = { dataset: { neoEndlessScrollFirstPageValue: '1', neoEndlessScrollPageValue: '1' } }
  const streams = [
    { action: 'replace', target: 'inbox_master_list' },
    { action: 'replace', targets: "#inbox_pane_status_pills[data-notification-id='n1']" }
  ]
  let currentList = list
  let currentHead = {}
  const context = {
    Controller: class {},
    document: {
      querySelector: () => ({ content: 'token' }), getElementById: id => id === "inbox_pane_status_pills" ? currentHead : currentList,
      createElement: () => ({ content: { querySelectorAll: () => streams } }),
      importNode: node => node
    },
    window: { location: { href: pageAddress } },
    listActionAddress,
    fetch: (url, options) => {
      return new Promise((resolve, reject) => {
        requests.push({ url, options, resolve, reject })
        if (!deferred) resolve({ ok: true, text: async () => '<turbo-stream></turbo-stream>' })
      })
    },
    Turbo: {
      renderStreamMessage: (html) => rendered.push(html),
      StreamActions: { replace() { rendered.push(this) } }
    },
    AbortController, setTimeout: () => 1, clearTimeout: () => {},
    console: { warn: (...said) => warned.push(said) }
  }
  const Controller = runInNewContext(`${source}\nPaneMarkReadDelayController`, context)
  const controller = new Controller()
  controller.urlValue = followAddress ? '/inbox/n1/mark_read?state_filters%5B%5D=read&notification=n1&quiet=1' : '/org/acme/inbox/n1/mark_read'
  controller.followAddressValue = followAddress
  controller.element = { isConnected: true, closest: (selector) => (selector === '.layout.hide-content' && laneShut ? {} : null) }
  controller.connect()
  return { controller, requests, rendered, warned, context, list, streams, replaceList: () => { currentList = { ...list } }, replaceHead: () => { currentHead = {} } }
}

test('a ticket still in view is marked as read and the answer is rendered', async () => {
  const { controller, requests, rendered } = build({ laneShut: false })

  await controller.markRead()

  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, '/org/acme/inbox/n1/mark_read')
  assert.equal(requests[0].options.method, 'PATCH')
  assert.equal(rendered.length, 1)
})

test('a ticket whose lane was shut before the time was up stays unread', async () => {
  const { controller, requests } = build({ laneShut: true })

  await controller.markRead()

  assert.equal(requests.length, 0)
})

// Above the organisations (review S3b round 3): the address takes the list state the page
// names when the timer fires (a search typed meanwhile), and keeps the open row and quiet
// from its own address: without the row the head of the lane would not follow after a
// search (the search drops it from the page's address), without quiet a toast would come.
test('above the organisations the timer follows the page and keeps its row and its quiet', async () => {
  const { controller, requests } = build({
    laneShut: false, followAddress: true,
    pageAddress: 'https://lalabase.test/inbox?search=Karton&state_filters%5B%5D=unread'
  })

  await controller.markRead()

  const address = new URL(requests[0].url)
  assert.equal(address.pathname, '/inbox/n1/mark_read')
  assert.equal(address.searchParams.get('search'), 'Karton')
  assert.deepEqual(address.searchParams.getAll('state_filters[]'), ['unread'])
  assert.equal(address.searchParams.get('notification'), 'n1')
  assert.equal(address.searchParams.get('quiet'), '1')
})

const finish = (request) => request.resolve({ ok: true, text: async () => '<turbo-stream></turbo-stream>' })

test('disconnect aborts a pending timer and an ignored abort cannot render into another lane', async () => {
  const f = build({ followAddress: true, deferred: true })
  const pending = f.controller.markRead()
  f.controller.disconnect()
  f.context.window.location.href = 'https://lalabase.test/inbox?notification=n2'
  assert.equal(f.requests[0].options.signal.aborted, true)
  finish(f.requests[0])
  await pending
  assert.deepEqual(f.rendered, [])
})

test('a response body arriving after disconnect is also discarded', async () => {
  const f = build({ followAddress: true, deferred: true })
  const pending = f.controller.markRead()
  let finishBody
  f.requests[0].resolve({ ok: true, text: () => new Promise(resolve => { finishBody = resolve }) })
  await setImmediate()
  f.controller.disconnect()
  finishBody('<turbo-stream></turbo-stream>')
  await pending
  assert.deepEqual(f.rendered, [])
})

// An answer is drawn only for the pane that asked and still shows. Each line is one way of
// no longer being that pane, and each holds on both pages: the checks stand before the
// branch that tells the pane of an organisation from the lane above the organisations.
// "Connected again" is the one case only the request itself tells apart: Stimulus keeps
// the controller of an element that is moved, so the element reads as in the page again.
const STALE = {
  'the pane disconnected': f => f.controller.disconnect(),
  'the lane shut in place': f => { f.controller.element.closest = () => ({}) },
  'the element left the page before Stimulus said so': f => { f.controller.element.isConnected = false },
  'the pane disconnected and connected again': f => { f.controller.disconnect(); f.controller.connect() }
}
for (const [where, followAddress] of [['in an organisation', false], ['above the organisations', true]]) {
  for (const [what, happens] of Object.entries(STALE)) {
    test(`${where}: an answer that arrives after ${what} is not drawn`, async () => {
      const f = build({ followAddress, deferred: true })
      const pending = f.controller.markRead()
      happens(f)
      finish(f.requests[0])
      await pending
      assert.deepEqual(f.rendered, [])
    })
  }

  test(`${where}: a refused answer is not drawn`, async () => {
    const f = build({ followAddress, deferred: true })
    const pending = f.controller.markRead()
    f.requests[0].resolve({ ok: false, text: async () => '<turbo-stream></turbo-stream>' })
    await pending
    assert.deepEqual(f.rendered, [])
  })
}

for (const change of ['search', 'redraw', 'endless scroll']) {
  test(`a newer ${change} keeps its list while the same notification head follows the timer`, async () => {
    const f = build({ followAddress: true, deferred: true })
    const pending = f.controller.markRead()
    if (change === 'search') f.context.window.location.href += '?search=new'
    if (change === 'redraw') f.replaceList()
    if (change === 'endless scroll') f.list.dataset.neoEndlessScrollPageValue = '2'
    finish(f.requests[0])
    await pending
    assert.deepEqual(f.rendered, [f.streams[1]])
  })
}

test('a current timer response applies the list and identity-scoped head synchronously', async () => {
  const f = build({ followAddress: true, deferred: true })
  const pending = f.controller.markRead()
  finish(f.requests[0])
  await pending
  assert.deepEqual(f.rendered, f.streams)
})

test('the timer cannot undo a more recent action on the same notification head', async () => {
  const f = build({ followAddress: true, deferred: true })
  const pending = f.controller.markRead()
  f.replaceHead()
  f.replaceList()
  finish(f.requests[0])
  await pending
  assert.deepEqual(f.rendered, [])
})

// The page's address is compared whole, not only the part the action's address is built
// from: the open row is kept from the timer's own address (keep: notification), so a page
// that names another row leaves the action's address as it was.
test('a page that names another row meanwhile keeps its list', async () => {
  const f = build({ followAddress: true, deferred: true, pageAddress: 'https://lalabase.test/inbox?notification=n1' })
  const pending = f.controller.markRead()
  f.context.window.location.href = 'https://lalabase.test/inbox?notification=n2'
  assert.equal(f.controller.address, f.requests[0].url)
  finish(f.requests[0])
  await pending
  assert.deepEqual(f.rendered, [f.streams[1]])
})

// Only "replace" is applied by hand (Turbo.StreamActions.replace). An answer that carries
// anything else is not half applied: the quiet answer of the server has no other action
// (all_inboxes_row_actions_spec.rb, "answers the timer with replace alone").
test('an answer with another action than replace is not applied in part', async () => {
  const f = build({ followAddress: true, deferred: true })
  const pending = f.controller.markRead()
  f.streams.push({ action: 'prepend', target: 'flash_messages' })
  finish(f.requests[0])
  await pending
  assert.deepEqual(f.rendered, [])
})

test('an aborted request says nothing, a failed one warns and neither throws', async () => {
  const aborted = build({ followAddress: true, deferred: true })
  const first = aborted.controller.markRead()
  aborted.requests[0].reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))
  await first
  assert.deepEqual(aborted.warned, [])
  assert.deepEqual(aborted.rendered, [])

  const failed = build({ followAddress: true, deferred: true })
  const second = failed.controller.markRead()
  failed.requests[0].reject(new TypeError('Failed to fetch'))
  await second
  assert.equal(failed.warned.length, 1)
  assert.deepEqual(failed.rendered, [])
})
