import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/neo_button_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class NeoButtonController")

// A tiny element with classes and listeners, enough for the controller.
function element(tagName, dataset = {}) {
  const listeners = {}
  const classes = new Set()
  return {
    tagName,
    dataset,
    form: null,
    classList: { add: (...c) => c.forEach(x => classes.add(x)), remove: (...c) => c.forEach(x => classes.delete(x)), contains: c => classes.has(c) },
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    removeEventListener: (type, fn) => { listeners[type] = (listeners[type] || []).filter(f => f !== fn) },
    dispatch: type => (listeners[type] || []).slice().forEach(fn => fn({ type })),
    closest: () => null
  }
}

function fixture({ confirmOnForm }) {
  const Controller = runInNewContext(`${source}\nNeoButtonController`, { Controller: class {}, confirm: () => true })
  const form = element("FORM", confirmOnForm ? { turboConfirm: "Sicher?" } : {})
  const button = element("BUTTON")
  button.form = form
  button.closest = selector => (selector === "form" ? form : null)
  const controller = new Controller()
  controller.element = button
  controller.loadingValue = false
  controller.confirmValue = ""
  controller.hasSpinnerTarget = false
  controller.hasContentTarget = false
  controller.connect()
  return { controller, form, button }
}

test("a form that asks first: no loading state before the answer", () => {
  const { controller, button } = fixture({ confirmOnForm: true })
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  assert.equal(button.classList.contains("pointer-events-none"), false)
})

test("a form that asks first: loading once Turbo submits, and back after the answer", () => {
  const { controller, form, button } = fixture({ confirmOnForm: true })
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  form.dispatch("turbo:submit-start")
  assert.equal(button.classList.contains("pointer-events-none"), true)
  form.dispatch("turbo:submit-end")
  assert.equal(button.classList.contains("pointer-events-none"), false)
})

test("a form without a question: loading at once, as before", () => {
  const { controller, button } = fixture({ confirmOnForm: false })
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  assert.equal(button.classList.contains("pointer-events-none"), true)
})
