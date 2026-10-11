import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const application = readFileSync(new URL('../../app/javascript/application.js', import.meta.url), 'utf8')
const start = application.indexOf('Turbo.StreamActions.replaceAddress =')
const end = application.indexOf('// Stores the most recent Turbo requests', start)
const source = application.slice(start, end)

test('replaceAddress publishes a row resynchronization after changing the URL', () => {
  const calls = []
  const Turbo = { StreamActions: {} }
  const window = {
    history: {
      replaceState: (state, title, url) => calls.push(['replaceState', state, title, url])
    }
  }
  const document = { dispatchEvent: (event) => calls.push(['dispatchEvent', event.type]) }
  const CustomEvent = class { constructor(type) { this.type = type } }
  runInNewContext(source, { Turbo, window, document, CustomEvent })

  Turbo.StreamActions.replaceAddress.call({ getAttribute: () => '/meetings?meeting_id=new-id' })

  assert.equal(calls.length, 2)
  assert.equal(calls[0][0], 'replaceState')
  assert.equal(calls[0][1].lane, true)
  assert.equal(calls[0][2], '')
  assert.equal(calls[0][3], '/meetings?meeting_id=new-id')
  assert.deepEqual(calls[1], ['dispatchEvent', 'lane:restored'])
})
