import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/ticket_pane_links_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class TicketPaneLinksController")

function controller() {
  const Controller = runInNewContext(`${source}\nTicketPaneLinksController`, { Controller: class {} })
  return new Controller()
}

// A click lands on whatever sits inside the link; closest finds the link.
function clickOn(link) {
  return { target: { closest: selector => (selector === "a[data-ticket-link]" ? link : null) } }
}

test("a link to another ticket leaves the pane", () => {
  const link = { dataset: { ticketLink: "", turboFrame: "ticket_display_frame" } }

  controller().leave(clickOn(link))

  assert.equal(link.dataset.turboFrame, "_top")
})

test("a click on anything else changes nothing", () => {
  assert.doesNotThrow(() => controller().leave(clickOn(null)))
})
