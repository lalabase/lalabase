import { test } from 'node:test'
import assert from 'node:assert/strict'
import { escapeOwned, OWNS_ESCAPE_ATTRIBUTE } from '../../../app/javascript/lib/escape_owner.js'

const emptyPage = { querySelector: () => null }

test('nobody owns Escape when no controller claims it and no layer stands', () => {
  const controllers = [{}, { ownsEscape: () => false }, null]

  assert.equal(escapeOwned(controllers, emptyPage), false)
})

test('a controller that claims Escape owns it', () => {
  const controllers = [{ ownsEscape: () => false }, { ownsEscape: () => true }]

  assert.equal(escapeOwned(controllers, emptyPage), true)
})

test('an open native dialog or a marked layer owns Escape without a controller', () => {
  let asked = null
  const page = { querySelector: (selector) => { asked = selector; return {} } }

  assert.equal(escapeOwned([], page), true)
  assert.match(asked, /dialog\[open\]/)
  assert.ok(asked.includes(`[${OWNS_ESCAPE_ATTRIBUTE}]`))
})

test('a property named ownsEscape that is not a method claims nothing', () => {
  assert.equal(escapeOwned([{ ownsEscape: true }], emptyPage), false)
})

test('an owner that throws counts as not owning and does not hide the others', () => {
  const original = console.error
  const reported = []
  console.error = (...args) => reported.push(args)
  try {
    const broken = { identifier: 'broken', ownsEscape: () => { throw new Error('missing target') } }

    assert.equal(escapeOwned([broken], emptyPage), false)
    assert.equal(escapeOwned([broken, { ownsEscape: () => true }], emptyPage), true)
    assert.equal(reported[0][1], 'broken')
  } finally {
    console.error = original
  }
})
