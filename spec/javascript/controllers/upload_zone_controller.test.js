// What: upload_zone_controller, the drop zone of the document forms (S4 of
//   doc/dokumentansicht_plan.md), against fakes of its targets.
// Type: node:test over the controller's own source in a vm context, the way
//   list_row_controller.test.js does it; the title rules live in
//   lib/upload_zone/title.js and have their own spec.
// Why: the button is off until a file is chosen, the zone names the file, the
//   title takes the file's name while it is empty or still the last suggestion
//   and never over typed words, and a drop is the same as a choice.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import * as title from "../../../app/javascript/lib/upload_zone/title.js"

const source = readFileSync(new URL("../../../app/javascript/controllers/upload_zone_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class UploadZoneController")

// The browser's DataTransfer, as far as the controller uses it: a list that
// takes files one by one and hands them back as `files`.
class DataTransfer {
  constructor() {
    this.stored = []
    this.items = { add: (file) => this.stored.push(file) }
  }

  get files() { return this.stored }
}

function fixture({ files = [], titleValue = "" } = {}) {
  const Controller = runInNewContext(`${source}\nUploadZoneController`, { Controller: class {}, DataTransfer, ...title })
  const controller = new Controller()
  const classes = new Set()
  controller.inputTarget = { files }
  controller.zoneTarget = { classList: { add: (...names) => names.forEach((n) => classes.add(n)), remove: (...names) => names.forEach((n) => classes.delete(n)) } }
  controller.nameTarget = { textContent: "" }
  controller.titleTarget = { value: titleValue }
  controller.submitTarget = { disabled: false }
  controller.hasNameTarget = true
  controller.hasTitleTarget = true
  controller.hasSubmitTarget = true
  controller.emptyLabelValue = "Noch keine Datei gewählt"
  controller.overClasses = ["border-ink", "bg-cream-100"]
  controller.connect()
  return { controller, classes }
}

test("without a file the button is off and the zone says so", () => {
  const { controller } = fixture()
  assert.equal(controller.submitTarget.disabled, true)
  assert.equal(controller.nameTarget.textContent, "Noch keine Datei gewählt")
  assert.equal(controller.titleTarget.value, "")
})

test("a chosen file names itself, suggests the title and switches the button on", () => {
  const { controller } = fixture()
  controller.inputTarget.files = [{ name: "Angebot_v2.pdf" }]
  controller.changed()
  assert.equal(controller.nameTarget.textContent, "Angebot_v2.pdf")
  assert.equal(controller.titleTarget.value, "Angebot_v2")
  assert.equal(controller.submitTarget.disabled, false)
})

test("a title the writer typed first stays", () => {
  const { controller } = fixture({ titleValue: "Mein Titel" })
  controller.inputTarget.files = [{ name: "Angebot_v2.pdf" }]
  controller.changed()
  assert.equal(controller.titleTarget.value, "Mein Titel")
})

test("a second file replaces the last suggestion but not typed words", () => {
  const { controller } = fixture()
  controller.inputTarget.files = [{ name: "Angebot_v2.pdf" }]
  controller.changed()
  controller.inputTarget.files = [{ name: "Plan.docx" }]
  controller.changed()
  assert.equal(controller.titleTarget.value, "Plan")
  controller.titleTarget.value = "Plan, korrigiert"
  controller.inputTarget.files = [{ name: "Plan_v3.docx" }]
  controller.changed()
  assert.equal(controller.titleTarget.value, "Plan, korrigiert")
})

test("a drop is a choice, and the zone lights up only while a file hovers", () => {
  const { controller, classes } = fixture()
  let prevented = 0
  const event = { preventDefault: () => prevented++, dataTransfer: { files: [{ name: "Skizze.png" }] } }
  controller.over(event)
  assert.deepEqual([...classes], ["border-ink", "bg-cream-100"])
  controller.drop(event)
  assert.equal(prevented, 2)
  assert.deepEqual([...classes], [])
  assert.equal(controller.inputTarget.files[0].name, "Skizze.png")
  assert.equal(controller.titleTarget.value, "Skizze")
  assert.equal(controller.submitTarget.disabled, false)
})

test("a drop of several files keeps the first alone, the one the zone names", () => {
  const { controller } = fixture()
  const files = [{ name: "Erste.pdf" }, { name: "Zweite.pdf" }, { name: "Dritte.pdf" }]
  controller.drop({ preventDefault: () => {}, dataTransfer: { files } })
  assert.equal(controller.inputTarget.files.length, 1)
  assert.equal(controller.inputTarget.files[0].name, "Erste.pdf")
  assert.equal(controller.nameTarget.textContent, "Erste.pdf")
  assert.equal(controller.titleTarget.value, "Erste")
})

test("a drop without files changes nothing", () => {
  const { controller } = fixture()
  controller.drop({ preventDefault: () => {}, dataTransfer: { files: [] } })
  assert.equal(controller.submitTarget.disabled, true)
})
