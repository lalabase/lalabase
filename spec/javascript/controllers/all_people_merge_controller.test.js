import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/all_people_merge_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class MergeController")

function fixture() {
  const fields = []
  const Controller = runInNewContext(`${source}\nMergeController`, {
    Controller: class {},
    document: {
      createElement: () => ({ dataset: {}, remove() { fields.splice(fields.indexOf(this), 1) } })
    }
  })
  const controller = new Controller()
  controller.initialize()
  controller.element = { toggleAttribute() {} }
  controller.tickTargets = []
  controller.countTargets = []
  controller.namesTargets = []
  controller.counterTargets = []
  controller.submitTargets = []
  Object.defineProperty(controller, "carriedTargets", {
    get: () => fields.filter(field => field.dataset.allPeopleMergeTarget === "carried")
  })
  const submit = () => {
    controller.carry({ target: { append: field => fields.push(field) } })
    return [...fields.map(field => field.value), ...controller.tickTargets.filter(tick => tick.checked).map(tick => tick.value)]
  }
  return { controller, fields, submit }
}

test("a retained form submits each off-screen selection once on every retry", () => {
  const { controller, submit } = fixture()
  controller.chosen.set("A", "Alpha").set("B", "Beta")

  assert.deepEqual(submit(), ["A", "B"])
  assert.deepEqual(submit(), ["A", "B"])
})

test("clearing after a failed submission removes the old people before retrying", () => {
  const { controller, fields, submit } = fixture()
  controller.chosen.set("A", "Alpha").set("B", "Beta")
  submit()
  controller.clear()
  assert.equal(fields.length, 0)

  controller.tickTargets = [{ value: "C", checked: true }, { value: "D", checked: true }]
  controller.tickTargets.forEach(target => controller.count({ target: { ...target, dataset: {} } }))
  assert.deepEqual(submit(), ["C", "D"])
})

test("unticking a formerly off-screen row removes it from the next request", () => {
  const { controller, submit } = fixture()
  controller.chosen.set("A", "Alpha").set("B", "Beta")
  submit()
  const tick = { value: "A", checked: false }
  controller.tickTargets = [tick]
  controller.count({ target: tick })

  assert.deepEqual(submit(), ["B"])
})
