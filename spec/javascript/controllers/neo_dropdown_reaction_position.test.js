import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/neo_dropdown_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class DropdownController')

test('reaction menus align above the right edge of their trigger', () => {
  const Controller = runInNewContext(`${source}\nDropdownController`, {
    Controller: class {}, window: { innerWidth: 375 }, Math
  })
  const controller = new Controller()
  controller.placementValue = 'top-end'
  controller.triggerTarget = { getBoundingClientRect: () => ({ right: 350, top: 200 }) }
  controller.menuTarget = { style: {}, offsetWidth: 240, offsetHeight: 58 }
  controller.positionMenu()
  assert.equal(controller.menuTarget.style.left, '110px')
  assert.equal(controller.menuTarget.style.top, '136px')
  controller.triggerTarget.getBoundingClientRect = () => ({ right: 100, top: 200 })
  controller.positionMenu()
  assert.equal(controller.menuTarget.style.left, '8px')
})

test('closing on scroll hides the top-layer menu without focusing the old trigger', () => {
  let focused = false
  let hidden = false
  const removed = []
  const Controller = runInNewContext(`${source}\nDropdownController`, {
    Controller: class {}, window: { removeEventListener: type => removed.push(type) }
  })
  const controller = new Controller()
  controller.isOpen = true
  controller.menuTarget = {
    style: {}, classList: { add() {} }, setAttribute() {},
    hasAttribute: () => true, hidePopover: () => { hidden = true }
  }
  controller.element = { classList: { remove() {} } }
  controller.triggerTarget = { focus: () => { focused = true }, setAttribute() {} }
  controller.removeOutsideClickListener = () => {}
  controller.removeInsideClickListener = () => {}
  controller.dispatch = () => {}
  controller.close({ restoreFocus: false })
  assert.equal(hidden, true)
  assert.equal(focused, false)
  assert.deepEqual(removed, ['scroll', 'resize'])
})
