import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_analysis_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class AssistantAnalysisController")

function fixture(response) {
  const dispatched = []
  const Controller = runInNewContext(`${source}\nAssistantAnalysisController`, {
    Controller: class {}, CustomEvent, FormData: class {},
    fetch: async () => response,
    document: { querySelector: () => ({ content: "token" }) },
    window: { dispatchEvent(event) { dispatched.push(event) } }
  })
  const c = new Controller()
  const button = { disabled: false }
  c.errorValue = "Fehler"
  c.formTarget = { action: "/save", querySelector: () => button }
  c.disclosureTarget = { hidden: false }
  c.successTarget = { hidden: true }
  c.errorTarget = { textContent: "" }
  c.messageTarget = { textContent: "" }
  c.linkTarget = { href: "" }
  return { c, dispatched, event: { preventDefault() {}, stopImmediatePropagation() {} } }
}

function jsonResponse(body, ok = true) {
  return { ok, headers: { get: () => "application/json" }, json: async () => body }
}

test("a saved analysis announces its meeting so an open meeting page refreshes its list", async () => {
  const f = fixture(jsonResponse({ message: "Gespeichert", url: "/meetings/m1", meeting_id: "m1" }))

  await f.c.save(f.event)

  assert.equal(f.dispatched.length, 1)
  assert.equal(f.dispatched[0].type, "assistant:analyses-changed")
  assert.equal(f.dispatched[0].detail.meetingId, "m1")
  assert.equal(f.c.successTarget.hidden, false)
})

test("a refused save announces nothing", async () => {
  const f = fixture(jsonResponse({ error: "Nicht verfügbar" }, false))

  await f.c.save(f.event)

  assert.equal(f.dispatched.length, 0)
  assert.equal(f.c.errorTarget.textContent, "Nicht verfügbar")
})
