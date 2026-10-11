import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import { availableWidth, fitCount, fullModeWidth } from "../../../app/javascript/lib/column_picker/fit.js"

// Exercise the actual controller with measured DOM values. Its imports are
// supplied by Rails' importmap in the browser, so provide them here for Node.
const source = readFileSync(new URL("../../../app/javascript/controllers/column_picker_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class ColumnPickerController")

function fixture(width, initialFit) {
  const minWidths = [120, 110, 110, 110]
  const table = {
    dataset: { fit: String(initialFit) },
    parentElement: { clientWidth: width },
    // Bare cells: dataset for the fit, rank and a style bag for the full-mode widths.
    querySelectorAll: () => minWidths.map((colMin, i) => ({ dataset: { colMin, rank: String(i + 1) }, style: {} })),
    // There is no trigger cell: the last header is the priority data column.
    querySelector: selector => selector === "thead th:last-child" ? {
      get offsetWidth() { return Number(table.dataset.fit) >= 4 ? 110 : 0 }
    } : null
  }
  const Controller = runInNewContext(`${source}\nColumnPickerController`, {
    Controller: class {}, availableWidth, fitCount, fullModeWidth,
    document: { getElementById: () => ({ querySelector: () => table }) }
  })
  const controller = new Controller()
  controller.frameValue = "tickets_list_frame"
  controller.fixedWidthValue = 358
  controller.hasListTarget = false
  controller.placeBoundary = () => {}
  controller.placePanel = () => {}
  return { controller, table }
}

test("repeated measurements keep all fitting columns, regardless of the previous visibility", () => {
  for (const initialFit of [3, 4]) {
    const { controller, table } = fixture(830, initialFit)
    const fits = []
    for (let i = 0; i < 4; i++) {
      controller.applyFit()
      fits.push(table.dataset.fit)
    }
    assert.deepEqual(fits, ["4", "4", "4", "4"])
  }
})

test("the final column fits exactly at its boundary and disappears below it", () => {
  const { controller, table } = fixture(808, 4) // 358 fixed + 450 ranked
  for (const [width, expected] of [[807, "3"], [808, "4"], [809, "4"], [807, "3"]]) {
    table.parentElement.clientWidth = width
    controller.applyFit()
    assert.equal(table.dataset.fit, expected, `list width ${width}`)
  }
})

test("the transition target and the settled measurement agree", () => {
  const { controller, table } = fixture(1500, 4)
  controller.settling = true
  controller.applyFit(830)
  assert.equal(table.dataset.fit, "4")
  table.parentElement.clientWidth = 830
  controller.settling = false
  controller.applyFit()
  assert.equal(table.dataset.fit, "4")
})

test("saving an empty pin selection explicitly clears the final pin", async () => {
  for (const pins of [[], ["participants"]]) {
    let request
    let reloads = 0
    const Controller = runInNewContext(`${source}\nColumnPickerController`, {
      Controller: class {}, FormData,
      document: { querySelector: () => ({ content: "csrf-token" }) },
      fetch: async (url, options) => {
        request = { url, ...options }
        return {
          ok: true, redirected: false,
          headers: { get: () => "application/json" },
          json: async () => ({ success: true })
        }
      }
    })
    const controller = new Controller()
    controller.editableValue = true
    controller.saveUrlValue = "/meetings/columns"
    controller.pinnedKeys = () => pins
    controller.setStatus = () => {}
    controller.reloadFrame = () => { reloads += 1 }

    await controller.save(["title", "participants"])

    assert.equal(request.method, "PATCH")
    assert.deepEqual(request.body.getAll("cols[]"), ["title", "participants"])
    assert.equal(request.body.has("pins[]"), true, "absent pins would preserve the existing selection")
    assert.deepEqual(request.body.getAll("pins[]"), pins.length ? pins : [""])
    assert.equal(reloads, 1)
  }
})
