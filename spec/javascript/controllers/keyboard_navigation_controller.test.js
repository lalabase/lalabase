import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/keyboard_navigation_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class KeyboardNavigationController')

const Controller = runInNewContext(`${source}\nKeyboardNavigationController`, { Controller: class {} })

test('Tab keeps the browser form order while ArrowDown enters the list', () => {
  const controller = new Controller()
  let prevented = 0
  let focused = 0
  controller.focusFirstRow = () => { focused += 1 }

  controller.handleSearchKeydown({ key: 'Tab', preventDefault: () => { prevented += 1 } })
  assert.equal(prevented, 0)
  assert.equal(focused, 0)

  controller.handleSearchKeydown({ key: 'ArrowDown', preventDefault: () => { prevented += 1 } })
  assert.equal(prevented, 1)
  assert.equal(focused, 1)
})

test('a mobile detail without a mounted list target has no navigable rows', () => {
  const controller = new Controller()
  controller.hasListContainerTarget = false

  assert.equal(controller.getNavigableRows().length, 0)
})
