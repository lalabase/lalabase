import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/return_referrer_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class ReturnReferrerController')

const current = 'https://app.example/inbox?notification=selected'
const profile = 'https://app.example/users/edit'
const preferences = 'https://app.example/user_preferences/edit'

function refresh({ single = false, url = profile, method = 'GET' } = {}) {
  const Controller = runInNewContext(`${source}\nReturnReferrerController`, {
    Controller: class {}, window: { location: { href: current } }
  })
  const controller = new Controller()
  controller.element = {
    href: profile,
    matches: () => single,
    querySelectorAll: () => [{ href: profile }, { href: preferences }]
  }
  const fetchOptions = { method, referrer: 'https://app.example/inbox' }
  controller.refresh({ detail: { url: new URL(url), fetchOptions } })
  return fetchOptions.referrer
}

test('a single management link sends the current selection as its referrer', () => {
  assert.equal(refresh({ single: true }), current)
})

test('every account entry in the list sends the current selection', () => {
  for (const url of [profile, preferences]) assert.equal(refresh({ url }), current)
})

test('requests to other destinations retain their referrer', () => {
  assert.equal(refresh({ url: 'https://app.example/inbox/counts' }), 'https://app.example/inbox')
})

test('writes to an entry destination retain their referrer', () => {
  assert.equal(refresh({ method: 'POST' }), 'https://app.example/inbox')
})
