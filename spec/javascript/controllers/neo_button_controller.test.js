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

// A link that writes and asks through Turbo (data-turbo-confirm): Turbo submits a form of
// its own, appended to <body>, whose action is the link's address without its query.
function linkFixture() {
  const docListeners = {}
  const document = {
    addEventListener: (type, fn) => { (docListeners[type] ||= []).push(fn) },
    removeEventListener: (type, fn) => { docListeners[type] = (docListeners[type] || []).filter(f => f !== fn) },
    dispatch: (type, target) => (docListeners[type] || []).slice().forEach(fn => fn({ type, target })),
    listeners: type => (docListeners[type] || []).length
  }
  class HTMLFormElement {
    constructor(action) { Object.assign(this, element("FORM"), { action }) }
  }
  const Controller = runInNewContext(`${source}\nNeoButtonController`, {
    Controller: class {}, confirm: () => { throw new Error("the link must not ask by itself") }, document, HTMLFormElement, URL
  })
  const link = element("A", { turboMethod: "delete", turboConfirm: "Sicher?" })
  link.href = "https://lalabase.test/org/o/projects/p/notes/n?frame_id=knowledge_display_frame"
  const controller = new Controller()
  controller.element = link
  controller.loadingValue = false
  controller.confirmValue = ""
  controller.hasSpinnerTarget = false
  controller.hasContentTarget = false
  controller.connect()
  const turboForm = action => new HTMLFormElement(action)
  return { controller, link, document, turboForm }
}

test("a link that asks through Turbo: no loading state and no question of its own at the click", () => {
  const { controller, link } = linkFixture()
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  assert.equal(link.classList.contains("pointer-events-none"), false)
})

test("a link that asks through Turbo: loading once its form submits, back when it ends", () => {
  const { controller, link, document, turboForm } = linkFixture()
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  document.dispatch("turbo:submit-start", turboForm("https://lalabase.test/org/o/projects/p/notes/other"))
  assert.equal(link.classList.contains("pointer-events-none"), false, "another form's submit is not this link's")
  const form = turboForm("https://lalabase.test/org/o/projects/p/notes/n")
  document.dispatch("turbo:submit-start", form)
  assert.equal(link.classList.contains("pointer-events-none"), true)
  assert.equal(document.listeners("turbo:submit-start"), 0)
  form.dispatch("turbo:submit-end")
  assert.equal(link.classList.contains("pointer-events-none"), false)
})

test("a link that asks through Turbo: a second click replaces the wait, disconnect ends it", () => {
  const { controller, document } = linkFixture()
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  controller.handleClick({ preventDefault() {}, stopPropagation() {} })
  assert.equal(document.listeners("turbo:submit-start"), 1)
  controller.disconnect()
  assert.equal(document.listeners("turbo:submit-start"), 0)
})
