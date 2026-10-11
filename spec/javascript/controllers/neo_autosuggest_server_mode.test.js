// What: neo_autosuggest_controller in server mode (url:), against fakes of its targets.
// Type: node:test over the controller's own source in a vm context (the way
//   list_row_controller.test.js does it); the search rules themselves live in
//   lib/autosuggest_search.js and have their own spec.
// Why: review of #944. Results of an older term stayed in the list while the next
//   search was on its way, and so did the keyboard mark on one of them: search A
//   shows ticket A, ArrowDown marks it, the user types B and presses Enter before B
//   answers, and ticket A is taken. After a failed search the old results stayed
//   choosable as well. New input and a failed search must leave nothing to choose.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"
import { ServerSearch } from "../../../app/javascript/lib/autosuggest_search.js"

const source = readFileSync(new URL("../../../app/javascript/controllers/neo_autosuggest_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class NeoAutosuggestController")

// Just enough of an element for what the controller touches.
class FakeElement {
  constructor(dataset = {}) {
    this.dataset = { ...dataset }
    this.children = []
    this.parent = null
    this.attributes = {}
    this.style = {}
    this.value = ""
    this.textContent = ""
    const classes = new Set()
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      toggle: (name, force) => (force ?? !classes.has(name)) ? classes.add(name) : classes.delete(name),
      contains: (name) => classes.has(name)
    }
  }

  appendChild(child) { child.parent = this; this.children.push(child); return child }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null }
  setAttribute(name, value) { this.attributes[name] = String(value) }
  removeAttribute(name) { delete this.attributes[name] }
  getAttribute(name) { return this.attributes[name] ?? null }
  querySelector(selector) {
    const slot = selector.match(/\[data-slot="(\w+)"\]/)[1]
    return this.children.find((child) => child.dataset.slot === slot) || null
  }
  cloneNode() {
    const copy = new FakeElement(this.dataset)
    this.children.forEach((child) => copy.appendChild(child.cloneNode()))
    return copy
  }
  contains(other) { return other === this || this.children.some((child) => child.contains(other)) }
  scrollIntoView() {}
  select() {}
  focus() {}
  dispatchEvent() {}
}

function manualTimers() {
  const pending = new Map()
  let next = 1
  return {
    setTimer: (fn) => { const id = next++; pending.set(id, fn); return id },
    clearTimer: (id) => { pending.delete(id) },
    flush: () => { const fns = [...pending.values()]; pending.clear(); fns.forEach((fn) => fn()) }
  }
}

function manualFetch() {
  const calls = []
  const fetch = () => new Promise((resolve, reject) => { calls.push({ resolve, reject }) })
  return { fetch, calls }
}

const tick = () => new Promise((resolve) => setImmediate(resolve))
const A = { value: "id-a", text: "#12 Login bug", detail: "Portal" }

function build() {
  const timers = manualTimers()
  const net = manualFetch()
  const Search = class extends ServerSearch {
    constructor(options) { super({ ...options, fetch: net.fetch, setTimer: timers.setTimer, clearTimer: timers.clearTimer }) }
  }
  const document = { addEventListener: () => {}, removeEventListener: () => {} }
  const Controller = runInNewContext(`${source}\nNeoAutosuggestController`, {
    Controller: class {}, ServerSearch: Search, document, console, Event: class { constructor(type) { this.type = type } }
  })

  const input = new FakeElement()
  const hidden = new FakeElement()
  const dropdown = new FakeElement()
  const status = new FakeElement()
  const list = new FakeElement()
  dropdown.appendChild(status)
  dropdown.appendChild(list)
  const template = new FakeElement()
  const optionShape = new FakeElement({ neoAutosuggestTarget: "option" })
  optionShape.appendChild(new FakeElement({ slot: "text" }))
  optionShape.appendChild(new FakeElement({ slot: "detail" }))
  template.content = { firstElementChild: optionShape }

  const controller = new Controller()
  const element = new FakeElement()
  element.id = "neo_autosuggest_ab12"
  Object.assign(controller, {
    element,
    inputTarget: input,
    hiddenInputTarget: hidden,
    dropdownTarget: dropdown,
    arrowTarget: new FakeElement(),
    statusTarget: status,
    hasStatusTarget: true,
    listTarget: list,
    hasListTarget: true,
    optionTemplateTarget: template,
    urlValue: "/org/o1/ticket_lookups?exclude=t1",
    selectedValue: "",
    selectedTextValue: "",
    hintTextValue: "hint",
    emptyTextValue: "empty",
    errorTextValue: "error",
    loadingTextValue: "loading"
  })
  Object.defineProperty(controller, "optionTargets", {
    get: () => list.children.filter((child) => child.dataset.neoAutosuggestTarget === "option")
  })
  controller.connect()

  const type = (text) => { input.value = text; controller.search() }
  const key = (name) => controller.handleKeydown({ key: name, preventDefault: () => {}, stopPropagation: () => {} })
  const answer = async (index, options) => { net.calls[index].resolve({ ok: true, json: async () => ({ options }) }); await tick() }
  return { controller, input, hidden, status, timers, net, type, key, answer }
}

test("shows the results of the term that was asked", async () => {
  const { controller, timers, type, answer } = build()

  type("log")
  timers.flush()
  await answer(0, [A])

  assert.deepEqual(controller.optionTargets.map((option) => option.dataset.value), ["id-a"])
})

test("new input takes the old results and their keyboard mark away, so Enter picks nothing", async () => {
  const { controller, hidden, timers, type, key, answer } = build()
  type("log")
  timers.flush()
  await answer(0, [A])
  key("ArrowDown")

  type("aud")
  key("Enter")

  assert.equal(controller.optionTargets.length, 0)
  assert.equal(hidden.value, "")
  assert.equal(controller.server.hasSelection, false)
})

test("a failed search leaves nothing to choose, only the message", async () => {
  const { controller, hidden, status, timers, net, type, key, answer } = build()
  type("log")
  timers.flush()
  await answer(0, [A])

  type("logi")
  timers.flush()
  net.calls[1].reject(new TypeError("Failed to fetch"))
  await tick()
  key("ArrowDown")
  key("Enter")

  assert.equal(controller.optionTargets.length, 0)
  assert.equal(status.textContent, "error")
  assert.equal(hidden.value, "")
})

// Review round 2 of #944: after a choice the list is closed and the focus stays in the
// field. ArrowDown opened the list through the client path, which left aria-expanded at
// "false", and a later search skipped showDropdown because the list counted as open.
test("ArrowDown on a closed list opens it the server way, announced as expanded", async () => {
  const { controller, input, timers, type, key, answer } = build()
  type("log")
  timers.flush()
  await answer(0, [A])
  controller.selectOption({ currentTarget: controller.optionTargets[0], preventDefault: () => {}, stopPropagation: () => {} })
  assert.equal(input.getAttribute("aria-expanded"), "false")

  key("ArrowDown")

  assert.equal(controller.isOpen, true)
  assert.equal(input.getAttribute("aria-expanded"), "true")
})

// Review round 3 of #944: the keyboard mark only changed a CSS class and the focus stays in
// the field, so a screen reader never heard which ticket Enter would take. The combobox
// pattern (WAI-ARIA): each option has an id, the field names the marked one in
// aria-activedescendant, and the marked option says aria-selected="true".
test("tells assistive technology which option the keyboard marks", async () => {
  const B = { value: "id-b", text: "#7 Login audit", detail: "Backoffice" }
  const { controller, input, timers, type, key, answer } = build()
  type("log")
  timers.flush()
  await answer(0, [A, B])
  const [first, second] = controller.optionTargets

  assert.ok(first.id && second.id && first.id !== second.id)
  assert.equal(input.getAttribute("aria-activedescendant"), null)

  key("ArrowDown")
  assert.equal(input.getAttribute("aria-activedescendant"), first.id)
  assert.equal(first.getAttribute("aria-selected"), "true")
  assert.equal(second.getAttribute("aria-selected"), "false")

  key("ArrowDown")
  assert.equal(input.getAttribute("aria-activedescendant"), second.id)
  assert.equal(first.getAttribute("aria-selected"), "false")

  type("aud")
  assert.equal(input.getAttribute("aria-activedescendant"), null)
})
