import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

// The lock of the takeover dialog: while its form is sent, no submit button sends it
// again. Turbo disables the button that sent the form and no other, and Enter sends
// through a default button nobody sees. Until 2026-11-17 the main button and the offers
// to merge stayed live meanwhile, and a click on one of them made a second copy.
const source = readFileSync(new URL("../../../app/javascript/controllers/person_takeover_modal_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class TakeoverController")

function fixture(buttons) {
  const Controller = runInNewContext(`${source}\nTakeoverController`, { TicketRelationModalController: class {} })
  const form = { querySelectorAll: (selector) => (selector === 'button[type="submit"]' ? buttons : []) }
  return { controller: new Controller(), form }
}

// The default button as Turbo leaves it (disabled), an offer hidden with its question
// (disabled), a live offer and the main button.
const buttons = () => [{ name: "default", disabled: true }, { name: "hidden offer", disabled: true },
                       { name: "offer", disabled: false }, { name: "main", disabled: false }]

test("the start of a submission disables every submit button of the form", () => {
  const all = buttons()
  const { controller, form } = fixture(all)

  controller.lock({ target: form })

  assert.deepEqual(all.map(button => button.disabled), [true, true, true, true])
})

test("a submission that failed gives back the buttons it took, and no other", () => {
  const all = buttons()
  const { controller, form } = fixture(all)
  controller.lock({ target: form })

  controller.unlock({ detail: { success: false } })

  assert.deepEqual(all.map(button => [button.name, button.disabled]),
                   [["default", true], ["hidden offer", true], ["offer", false], ["main", false]])
})

test("a submission that succeeded keeps them disabled: the page is leaving", () => {
  const all = buttons()
  const { controller, form } = fixture(all)
  controller.lock({ target: form })

  controller.unlock({ detail: { success: true } })

  assert.deepEqual(all.map(button => button.disabled), [true, true, true, true])
})

test("an end without a start changes nothing", () => {
  const all = buttons()
  const { controller } = fixture(all)

  controller.unlock({ detail: { success: false } })

  assert.deepEqual(all.map(button => button.disabled), [true, true, false, false])
})
