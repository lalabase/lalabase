import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const source = readFileSync(new URL('../../../app/javascript/controllers/index_page_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace('export default class', 'class IndexPageController')

test('the matching lane cleanup event resets src and renders the placeholder', () => {
  const removed = []
  const frame = { removeAttribute: (name) => removed.push(name) }
  const document = { getElementById: (id) => id === 'meeting_display_frame' ? frame : null }
  const Controller = runInNewContext(`${source}\nIndexPageController`, {
    Controller: class {}, document, window: {}, URL, URLSearchParams,
    readLaneParams: () => null, laneParamNames: () => [], listPart: () => '',
    restoration: () => null, previewAddress: () => null, detailAddress: () => null
  })
  const controller = new Controller()
  let cleaned = 0
  controller.frameIdValue = 'meeting_display_frame'
  controller.cleanFrame = () => { cleaned += 1 }

  controller.clearDetail({ detail: { frameId: 'another_frame' } })
  controller.clearDetail({ detail: { frameId: 'meeting_display_frame' } })

  assert.deepEqual(removed, ['src'])
  assert.equal(cleaned, 1)
})
