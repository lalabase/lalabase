// Template management in the assistant composer: the manage switch states its
// position (aria-pressed), never outlives the picker or its meeting, and a
// delete does not throw keyboard focus out of the picker.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/meeting_analysis_composer_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class MeetingAnalysisComposer")

// Just enough of an element for filter(): children, attributes, a focus that
// the fake document records, and removal that drops focus the way a browser
// does when the focused node leaves the tree.
function fixture({ prompts, reload = prompts => ({ prompts, can_manage: true }) } = {}) {
  const doc = { activeElement: null, body: { tag: "body" } }
  function element(tag) {
    return {
      tag, dataset: {}, attributes: {}, children: [], textContent: "", hidden: false, parent: null,
      setAttribute(name, value) { this.attributes[name] = value },
      addEventListener(type, callback) { this[`on${type}`] = callback },
      append(...nodes) { nodes.forEach(node => { node.parent = this; this.children.push(node) }) },
      focus() { doc.activeElement = this },
      contains(node) { for (let n = node; n; n = n.parent) if (n === this) return true; return false }
    }
  }
  doc.createElement = element
  doc.querySelector = () => ({ content: "token" })

  let library = [...prompts]
  const requests = []
  const fetch = async (url, options = {}) => {
    requests.push(options.method || "GET")
    if (options.method === "DELETE") {
      const { prompt_id: id } = JSON.parse(options.body)
      library = library.filter(prompt => prompt.id !== id)
      return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ message: "Vorlage gelöscht." }) }
    }
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => reload(library) }
  }

  const Klass = runInNewContext(`${source}\nMeetingAnalysisComposer`, {
    Controller: class {}, Event, URL, fetch, document: doc,
    window: { location: { origin: "http://localhost" }, confirm: () => true },
    MutationObserver: class { observe() {} disconnect() {} }
  })
  const c = new Klass()
  let referenceKeys = "Meeting:m1"
  const root = { querySelectorAll: () => [{ dataset: { referenceKeys } }] }
  c.element = { closest: () => root, addEventListener() {}, removeEventListener() {}, querySelector: () => null }

  const picker = element("div")
  const search = element("input")
  search.value = ""
  const list = element("div")
  list.replaceChildren = function (...nodes) {
    if (this.contains(doc.activeElement)) doc.activeElement = doc.body
    this.children = []
    this.textContent = ""
    this.append(...nodes)
  }
  list.querySelectorAll = function (selector) {
    assert.equal(selector, "button[data-template-delete]")
    return this.children.flatMap(row => row.children).filter(node => "templateDelete" in node.dataset)
  }
  picker.append(search, list)
  const manage = element("button")
  manage.hidden = true
  manage.dataset.deleteLabel = "Löschen"
  manage.dataset.deleteConfirm = "Vorlage „__TITLE__“ wirklich löschen?"
  manage.attributes["aria-pressed"] = "false"

  Object.assign(c, {
    urlValue: "/analysis_prompts", errorValue: "Fehler", emptyValue: "Keine Vorlagen", draftValue: false,
    toolsTarget: { hidden: true, open: true }, pickerTarget: picker, searchTarget: search, listTarget: list,
    manageTarget: manage, titleBoxTarget: { hidden: true }, titleTarget: element("input"),
    statusTarget: { textContent: "" }, saveTemplateTarget: { hidden: true }, chooseTemplateTarget: { hidden: false },
    hasRevisionTarget: false
  })
  c.connect()

  const settle = () => new Promise(resolve => setImmediate(resolve))
  const rows = () => list.children
  const deleteButtons = () => list.querySelectorAll("button[data-template-delete]")
  return {
    c, doc, picker, search, list, manage, requests, rows, deleteButtons, settle,
    changeReferences(keys) { referenceKeys = keys; c.syncReferences() },
    async openManaging() {
      c.choose()
      await settle()
      c.toggleManage()
    }
  }
}

const library = [
  { id: "p1", title: "Entscheidungen", prompt_text: "Fasse Entscheidungen zusammen." },
  { id: "p2", title: "Risiken", prompt_text: "Nenne Risiken." },
  { id: "p3", title: "Aufgaben", prompt_text: "Liste Aufgaben." }
]

test("the manage switch carries aria-pressed in step with the delete buttons", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()
  assert.equal(f.manage.attributes["aria-pressed"], "true")
  assert.equal(f.deleteButtons().length, 3)

  f.c.toggleManage()
  assert.equal(f.manage.attributes["aria-pressed"], "false")
  assert.equal(f.deleteButtons().length, 0)
})

test("closing the picker ends management mode", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()

  f.c.title()

  assert.equal(f.picker.hidden, true)
  assert.equal(f.c.managing, false)
  assert.equal(f.manage.attributes["aria-pressed"], "false")
  f.c.choose()
  await f.settle()
  assert.equal(f.deleteButtons().length, 0, "reopening the picker shows the library, not its delete buttons")
})

test("folding the tools shut ends management mode", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()

  f.c.toolsTarget.open = false
  f.c.toolsToggled()

  assert.equal(f.c.managing, false)
  assert.equal(f.manage.attributes["aria-pressed"], "false")
  assert.equal(f.deleteButtons().length, 0)
})

test("a change of the referenced meeting ends management mode", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()

  f.changeReferences("Meeting:m2")

  assert.equal(f.picker.hidden, true)
  assert.equal(f.c.managing, false)
  assert.equal(f.manage.attributes["aria-pressed"], "false")
})

test("after a delete focus moves to the next row's delete button and the confirmation is written after it", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()
  // Records every write to the live region together with where focus was.
  const writes = []
  f.c.statusTarget = {
    get textContent() { return writes.at(-1)?.[0] ?? "" },
    set textContent(value) { writes.push([value, f.doc.activeElement]) }
  }
  const target = f.deleteButtons()[1]
  target.focus()

  await target.onclick()

  assert.deepEqual(f.requests.slice(-2), ["DELETE", "GET"])
  const next = f.deleteButtons()[1]
  assert.equal(f.deleteButtons().length, 2)
  assert.equal(next.attributes["aria-label"], "Löschen: Aufgaben")
  assert.equal(f.doc.activeElement, next, "the row that moved up keeps the keyboard in the list")
  assert.deepEqual(writes.map(([value]) => value), ["", "Vorlage gelöscht."])
  assert.equal(writes.at(-1)[1], next, "announced after the focus move")
})

test("deleting the last row moves focus to the template search", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()
  const last = f.deleteButtons()[2]
  last.focus()

  await last.onclick()

  assert.equal(f.doc.activeElement, f.search)
  assert.equal(f.c.statusTarget.textContent, "Vorlage gelöscht.")
})

test("a delete does not pull focus out of a field the user moved on to", async () => {
  const f = fixture({ prompts: library })
  await f.openManaging()
  const composer = f.doc.createElement("textarea")

  const deleting = f.deleteButtons()[0].onclick()
  composer.focus()
  await deleting

  assert.equal(f.doc.activeElement, composer)
  assert.equal(f.c.statusTarget.textContent, "Vorlage gelöscht.")
})
