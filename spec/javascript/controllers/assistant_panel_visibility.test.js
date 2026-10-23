// What: which page objects the assistant counts as seen (assistant_panel_controller
//   #pageContextVisible, used by #pageContexts), in each browser the application admits.
// Type: node:test over the controller's source with fake markers; no browser.
// Why: allow_browser :modern admits Chrome 120, Firefox 121 and Safari 17.2. The first
//   two know checkVisibility only with its original option name (checkVisibilityCSS) and
//   ignore the newer visibilityProperty; Safari before 17.4 has no checkVisibility at
//   all. Asked the wrong way, both offered the meeting hidden behind the ticket tab at
//   the narrow stage (doc/ticket_meeting_panel_plan.md S2, S3), and the fakes of
//   assistant_panel_page_contexts.test.js answer any question, so they could not tell.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/assistant_panel_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class AssistantPanelController")

function marker({ id = "meeting", hasBox = true, visibility = "visible", closedLane = false, inAssistant = false } = {}) {
  return {
    dataset: { assistantContext: id, assistantContextType: "Meeting", assistantContextLabel: id },
    visibility, hasBox, inAssistant,
    closest: () => (closedLane ? {} : null),
    getClientRects: () => (hasBox ? [{}] : [])
  }
}

// With the API, the marker answers as Chrome 120 and Firefox 121 do: only the original
// option name makes it look at the visibility property. Without it, Safari 17.2.
function fixture(markers, visibilityAPI) {
  if (visibilityAPI) {
    for (const each of markers) {
      each.checkVisibility = ({ checkVisibilityCSS = false } = {}) =>
        each.hasBox && (!checkVisibilityCSS || each.visibility === "visible")
    }
  }
  const Controller = runInNewContext(`${source}\nAssistantPanelController`, {
    Controller: class {},
    document: { querySelectorAll: () => markers },
    getComputedStyle: each => ({ visibility: each.visibility })
  })
  const controller = new Controller()
  controller.element = { contains: each => each.inAssistant }
  return controller
}

// The controller runs in its own realm: its arrays are not this realm's arrays.
const keysOf = controller => Array.from(controller.pageContexts(), context => context.key)

for (const visibilityAPI of [true, false]) {
  const browser = visibilityAPI ? "checkVisibility with its original options" : "no checkVisibility"

  test(`${browser}: a visible meeting is on offer`, () => {
    assert.deepEqual(keysOf(fixture([marker()], visibilityAPI)), ["Meeting:meeting"])
  })

  for (const [state, options] of [
    ["a closed panel (display:none)", { hasBox: false }],
    ["the column behind the other tab (visibility:hidden)", { visibility: "hidden" }],
    ["visibility:collapse", { visibility: "collapse" }]
  ]) {
    test(`${browser}: ${state} is not on offer`, () => {
      assert.deepEqual(keysOf(fixture([marker(options)], visibilityAPI)), [])
    })
  }

  test(`${browser}: hidden markers do not keep a later visible one from the offer`, () => {
    const controller = fixture([
      marker({ id: "closed", hasBox: false }),
      marker({ id: "behind", visibility: "hidden" }),
      marker({ id: "visible" })
    ], visibilityAPI)
    assert.deepEqual(keysOf(controller), ["Meeting:visible"])
  })

  test(`${browser}: a citation in the assistant and a closed lane stay out`, () => {
    const controller = fixture([
      marker({ id: "citation", inAssistant: true }),
      marker({ id: "closing", closedLane: true })
    ], visibilityAPI)
    assert.deepEqual(keysOf(controller), [])
  })
}
