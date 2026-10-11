import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/post_reaction_tooltip_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class TooltipController')

function setup() {
  const timers = new Map()
  let timerId = 0
  const Controller = runInNewContext(`${source}\nTooltipController`, {
    Controller: class {}, Date, Math,
    setTimeout: fn => { timers.set(++timerId, fn); return timerId },
    clearTimeout: id => timers.delete(id)
  })
  const controller = new Controller()
  let shown = 0
  controller.show = () => shown++
  controller.hide = () => {}
  const press = { pointerType: 'touch', clientX: 20, clientY: 20 }
  const click = () => {
    let prevented = false
    controller.click({ preventDefault: () => { prevented = true }, stopImmediatePropagation() {} })
    return prevented
  }
  return { controller, timers, press, click, shown: () => shown }
}

test('a long press reveals names and consumes the following reaction click', () => {
  const { controller, timers, press, click, shown } = setup()
  controller.startPress(press)
  timers.get(controller.pressTimer)()
  controller.endPress()
  assert.equal(shown(), 1)
  assert.equal(click(), true)
  assert.equal(click(), false, 'a later intentional click is not swallowed')
})

test('a new pointer gesture clears any unconsumed synthetic-click suppression', () => {
  const { controller, timers, press, click } = setup()
  controller.startPress(press)
  timers.get(controller.pressTimer)()
  controller.endPress()
  controller.startPress(press)
  controller.endPress()
  assert.equal(click(), false)
})

test('a short tap remains a normal reaction toggle', () => {
  const { controller, timers, press, click, shown } = setup()
  controller.startPress(press)
  controller.endPress()
  assert.equal(timers.size, 0)
  assert.equal(shown(), 0)
  assert.equal(click(), false)
})

test('scrolling or pointer cancellation cancels the pending tooltip', () => {
  for (const cancel of [c => c.movePress({ clientX: 31, clientY: 20 }), c => c.cancelPress()]) {
    const { controller, timers, press, shown } = setup()
    controller.startPress(press)
    cancel(controller)
    assert.equal(timers.size, 0)
    assert.equal(shown(), 0)
  }
})

test('mouse presses do not schedule touch gestures, and disconnect clears timers', () => {
  const { controller, timers, press } = setup()
  controller.startPress({ ...press, pointerType: 'mouse' })
  assert.equal(timers.size, 0)
  controller.startPress(press)
  controller.disconnect()
  assert.equal(timers.size, 0)
})
