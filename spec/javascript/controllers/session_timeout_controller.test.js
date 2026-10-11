import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/session_timeout_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class SessionTimeoutController')

function setup() {
  let now = Date.parse('2026-09-18T10:00:00Z')
  const listeners = new Map()
  const calls = []
  const token = { content: 'old' }
  const input = { value: 'old' }
  const document = {
    hidden: false,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name),
    querySelector: () => token,
    querySelectorAll: () => [input]
  }
  const window = { location: new URL('https://example.test/tickets/1'),
    addEventListener: document.addEventListener, removeEventListener: document.removeEventListener }
  const response = { ok: true, status: 200, json: async () => ({
    user_id: 'user-1', csrf_token: 'fresh', expires_at: new Date(now + 1800000).toISOString()
  }) }
  const Controller = runInNewContext(`${source}\nSessionTimeoutController`, {
    Controller: class {}, document, window, URL, AbortController,
    Date: class extends Date { static now() { return now } },
    setInterval: () => 1, clearInterval: () => {}, setTimeout: () => 2, clearTimeout: () => {},
    fetch: async (...args) => { calls.push(args); return response }
  })
  const controller = new Controller()
  Object.assign(controller, {
    expiresAtValue: new Date(now + 1800000).toISOString(), warnSecondsValue: 60,
    touchThrottleMsValue: 300000, touchUrlValue: '/session/touch',
    loginUrlValue: '/users/sign_in', userIdValue: 'user-1',
    hasModalTarget: true, hasCountdownTarget: true,
    modalTarget: { open: false, showModal() { this.open = true }, close() { this.open = false } },
    countdownTarget: {}, warningTarget: {}, expiredTarget: {}, checkingTarget: {}, errorTarget: {},
    accountChangedTarget: {},
  })
  return { controller, document, window, listeners, calls, response, token, input,
    advance: ms => { now += ms }, flush: () => new Promise(resolve => setImmediate(resolve)) }
}

test('checks on connect and rechecks a returning tab despite the activity throttle', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.controller.lastTouchAt = Date.now()
  h.advance(60000)
  h.response.status = 401
  h.response.ok = false
  assert.equal(typeof h.listeners.get('focus'), 'function')
  h.listeners.get('focus')()
  assert.equal(h.controller.modalTarget.open, false, 'a deadline far away is verified without a dialog')
  let prevented = false
  h.controller.guardSubmission({ preventDefault: () => { prevented = true }, stopImmediatePropagation() {} })
  assert.equal(prevented, true, 'stale forms are blocked during verification')
  await h.flush()
  assert.equal(h.controller.expiredTarget.hidden, false)
  assert.equal(h.window.location.pathname, '/tickets/1', 'draft page is retained')
  assert.ok(h.calls.every(([url]) => String(url).includes('check=1')))
})

test('polls idle sessions without refreshing their deadline', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(30000)
  h.controller.tick()
  await h.flush()
  assert.equal(h.calls.length, 2)
  assert.ok(h.calls.every(([url, options]) => String(url).includes('check=1') && options.cache === 'no-store'))
})

test('failed renewal keeps the warning visible', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.controller.showWarning(30)
  h.response.ok = false
  h.response.status = 500
  await h.controller.stayLoggedIn()
  assert.equal(h.controller.modalTarget.open, true)
  assert.equal(h.controller.errorTarget.hidden, false)
})

test('reauthentication refreshes CSRF in existing forms and only resumes the same account', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.controller.showExpired()
  h.response.json = async () => ({ user_id: 'other-user', csrf_token: 'wrong', expires_at: h.controller.expiresAtValue })
  await h.controller.checkSession()
  assert.equal(h.controller.modalTarget.open, true)
  assert.equal(h.controller.accountChangedTarget.hidden, false)
  assert.notEqual(h.token.content, 'wrong')
  h.response.json = async () => ({ user_id: 'user-1', csrf_token: 'new-token', expires_at: h.controller.expiresAtValue })
  await h.controller.checkSession()
  assert.equal(h.controller.modalTarget.open, false)
  assert.equal(h.token.content, 'new-token')
  assert.equal(h.input.value, 'new-token')
})

test('blocks submission during expiry checks and intercepts Turbo login redirects', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  let prevented = 0
  h.controller.handleResponse({ detail: { fetchResponse: { response: {
    status: 200, redirected: true, url: 'https://example.test/users/sign_in'
  } } }, preventDefault: () => prevented++ })
  assert.equal(h.controller.expiredTarget.hidden, false)
  h.controller.guardSubmission({ preventDefault: () => prevented++, stopImmediatePropagation: () => {} })
  assert.equal(prevented, 2)
  h.controller.disconnect()
  assert.equal(h.listeners.size, 0)
})

test('uses the server deadline when another tab has extended the session', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(1801000)
  h.controller.tick()
  assert.equal(h.controller.modalTarget.open, true)
  await h.flush()
  assert.equal(h.controller.modalTarget.open, false)
  assert.equal(h.window.location.pathname, '/tickets/1')
})

test('hidden tabs do not poll and visibility restoration checks immediately', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.document.hidden = true
  h.advance(60000)
  h.controller.tick()
  assert.equal(h.calls.length, 1)
  h.document.hidden = false
  h.listeners.get('visibilitychange')()
  await h.flush()
  assert.equal(h.calls.length, 2)
})

test('concurrent status requests are deduplicated and a disconnected page ignores late results', async () => {
  const h = setup()
  let finish
  h.response.json = () => new Promise(resolve => { finish = resolve })
  h.controller.connect()
  await h.flush()
  h.controller.checkSession()
  assert.equal(h.calls.length, 1)
  h.controller.disconnect()
  finish({ user_id: 'user-1', csrf_token: 'late-token', expires_at: h.controller.expiresAtValue })
  await h.flush()
  assert.equal(h.token.content, 'old')
  assert.equal(h.controller.modalTarget.open, false)
})

test('only real activity extends a session and renewal stays throttled', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(300001)
  await h.controller.checkSession()
  h.controller.handleActivity()
  await h.flush()
  const extensions = () => h.calls.filter(([url]) => !String(url).includes('check=1'))
  assert.equal(extensions().length, 1)
  h.controller.handleActivity()
  await h.flush()
  assert.equal(extensions().length, 1)
})

test('an explicit renewal waits for an in-flight status poll and then extends', async () => {
  const h = setup()
  const data = { user_id: 'user-1', csrf_token: 'fresh', expires_at: h.controller.expiresAtValue }
  let finish
  h.response.json = () => new Promise(resolve => { finish = resolve })
  h.controller.connect()
  await h.flush()
  const renewed = h.controller.stayLoggedIn()
  h.response.json = async () => data
  finish(data)
  await renewed
  assert.equal(h.calls.length, 2)
  assert.equal(new URL(h.calls[1][0]).searchParams.has('check'), false)
})

test('a rejected login redirect cannot trigger successful-submit draft cleanup', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  const form = {}
  h.controller.handleResponse({ target: form, detail: { fetchResponse: { response: {
    status: 200, redirected: true, url: 'https://example.test/users/sign_in'
  } } }, preventDefault() {} })
  const event = { target: form, detail: { success: true } }
  h.listeners.get('turbo:submit-end')(event)
  assert.equal(event.detail.success, false)
  const laterSubmission = { target: form, detail: { success: true } }
  h.listeners.get('turbo:submit-end')(laterSubmission)
  assert.equal(laterSubmission.detail.success, true)
})

test('an old successful poll cannot undo a newer authentication failure', async () => {
  const h = setup()
  let finish
  h.response.json = () => new Promise(resolve => { finish = resolve })
  h.controller.connect()
  await h.flush()
  h.controller.handleResponse({ detail: { fetchResponse: { response: { status: 401 } } }, preventDefault() {} })
  finish({ user_id: 'user-1', csrf_token: 'obsolete-token', expires_at: h.controller.expiresAtValue })
  await h.flush()
  assert.equal(h.controller.state, 'expired')
  assert.equal(h.controller.modalTarget.open, true)
  assert.equal(h.token.content, 'old')
})

test('Escape cannot reach underlying modal handlers while session dialog is open', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.controller.showExpired()
  let prevented = false
  let stopped = false
  h.listeners.get('keydown')({ key: 'Escape', preventDefault: () => { prevented = true }, stopImmediatePropagation: () => { stopped = true } })
  assert.equal(prevented, true)
  assert.equal(stopped, true)
})

test('returning within 30 seconds blocks submission until fresh CSRF verification finishes', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(1000)
  let finish
  h.response.json = () => new Promise(resolve => { finish = resolve })
  h.listeners.get('focus')()
  await h.flush()
  let prevented = false
  h.controller.guardSubmission({ preventDefault: () => { prevented = true }, stopImmediatePropagation() {} })
  assert.equal(prevented, true)
  assert.equal(h.controller.modalTarget.open, true)
  finish({ user_id: 'user-1', csrf_token: 'rotated-token', expires_at: h.controller.expiresAtValue })
  await h.flush()
  assert.equal(h.controller.modalTarget.open, false)
  assert.equal(h.token.content, 'rotated-token')
})

test('a failed status attempt does not make an unverified session fresh', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(30000)
  h.response.ok = false
  h.response.status = 500
  await h.controller.checkSession()
  assert.equal(h.controller.stale(), true)
})

test('routine verification of a live session never opens the dialog', async () => {
  const h = setup()
  h.controller.connect()
  assert.equal(h.controller.modalTarget.open, false, 'a freshly rendered page does not flash the dialog')
  await h.flush()
  assert.equal(h.controller.modalTarget.open, false)
  h.advance(30001)
  h.listeners.get('mousemove')()
  assert.equal(h.controller.modalTarget.open, false, 'one poll interval alone is no reason to block')
  await h.flush()
  assert.equal(h.controller.modalTarget.open, false)
  h.listeners.get('focus')()
  assert.equal(h.controller.modalTarget.open, false, 'a short absence does not block a live session')
  await h.flush()
  assert.equal(h.controller.modalTarget.open, false)
  assert.equal(h.calls.length, 3, 'the session is still verified, only silently')
  assert.ok(h.calls.every(([url]) => String(url).includes('check=1')))
})

test('a returning tab still blocks once the deadline is inside the warning window', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(1770000)
  h.response.json = async () => ({
    user_id: 'user-1', csrf_token: 'fresh', expires_at: h.controller.expiresAtValue
  })
  h.listeners.get('focus')()
  assert.equal(h.controller.modalTarget.open, true, 'a near deadline still blocks before verification')
  assert.equal(h.controller.checkingTarget.hidden, false)
  await h.flush()
  assert.equal(h.controller.warningTarget.hidden, false, 'the countdown takes over after verification')
  assert.equal(h.controller.countdownTarget.textContent, '30')
})

test('an expired deadline still blocks the page before the server answers', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.advance(1800001)
  h.listeners.get('mousemove')()
  assert.equal(h.controller.modalTarget.open, true, 'a passed deadline blocks even on plain activity')
  assert.equal(h.controller.checkingTarget.hidden, false)
})

test('a failed check does not let activity hammer the endpoint', async () => {
  const h = setup()
  h.controller.connect()
  await h.flush()
  h.response.ok = false
  h.response.status = 503
  h.advance(30001)
  const before = h.calls.length
  for (let i = 0; i < 60; i++) {
    h.listeners.get('mousemove')()
    await h.flush()
  }
  assert.equal(h.calls.length - before, 1, 'the poll interval throttles the retry, the dialog no longer does')
  assert.equal(h.controller.stale(), true, 'a failed check must not mark an unverified session fresh')
  h.advance(30001)
  h.listeners.get('mousemove')()
  await h.flush()
  assert.equal(h.calls.length - before, 2, 'once the interval has passed it tries again')
})
