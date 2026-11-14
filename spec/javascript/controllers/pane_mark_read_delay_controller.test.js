import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { listActionAddress } from '../../../app/javascript/lib/inbox_live.js'

// The delayed mark-as-read gives the reader a few seconds for a look. It
// counts only while the ticket is still in view: a lane shut in place hides
// it by a class on the grid and leaves this controller connected.

const source = readFileSync(new URL('../../../app/javascript/controllers/pane_mark_read_delay_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class PaneMarkReadDelayController')

function build({ laneShut, followAddress = false, pageAddress = 'https://lalabase.test/inbox' }) {
  const requests = []
  const rendered = []
  const context = {
    Controller: class {},
    document: { querySelector: () => ({ content: 'token' }), getElementById: () => null },
    window: { location: { href: pageAddress } },
    listActionAddress,
    fetch: async (url, options) => { requests.push({ url, options }); return { ok: true, text: async () => '<turbo-stream></turbo-stream>' } },
    Turbo: { renderStreamMessage: (html) => rendered.push(html) },
    console
  }
  const Controller = runInNewContext(`${source}\nPaneMarkReadDelayController`, context)
  const controller = new Controller()
  controller.urlValue = followAddress ? '/inbox/n1/mark_read?state_filters%5B%5D=read&notification=n1&quiet=1' : '/org/acme/inbox/n1/mark_read'
  controller.followAddressValue = followAddress
  controller.element = { closest: (selector) => (selector === '.layout.hide-content' && laneShut ? {} : null) }
  return { controller, requests, rendered }
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
