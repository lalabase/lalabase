// What: what Back and Forward restore (lib/lane/history.js, D2 of
//   doc/dateivorschau_plan.md), as sequences over addresses.
// Type: node:test unit spec; no browser.
// Why: list → document → preview → Back → Back must give the document and then
//   the list; a filter change between document and preview, then two Backs,
//   must restore the PAGE with the old filter, not only the lane; every entry
//   is restored, Turbo's own included (the lib says why).
import { test } from "node:test"
import assert from "node:assert/strict"
import { restoration, previewAddress, SELECTION_PLACEHOLDER, PREVIEW_PLACEHOLDER } from "../../../../app/javascript/lib/lane/history.js"
import { parseLaneParams, listPart } from "../../../../app/javascript/lib/lane/params.js"

const groups = parseLaneParams(JSON.stringify({ selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] }))
const INDEX = "http://x.test/org/o1/projects/p1/knowledge"
const at = (query) => new URL(`${INDEX}${query}`)
const shown = (query) => listPart(query, groups)

test("list → document → preview → Back → Back: the frame with the document, then the closed lane", () => {
  const list = shown("?type=all&search=x")
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&search=x&document_id=D"), groups }),
    { kind: "frame", selection: { param: "document_id", id: "D" }, preview: null })
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&search=x&document_id=D&preview=V"), groups }),
    { kind: "frame", selection: { param: "document_id", id: "D" }, preview: { param: "preview", id: "V" } })
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&search=x"), groups }), { kind: "close" })
})

test("a filter change between document and preview: Back to the old filter restores the page", () => {
  const afterFilter = shown("?type=all&search=y")
  assert.deepEqual(restoration({ shownListQuery: afterFilter, address: at("?type=all&search=x&document_id=D"), groups }), { kind: "page" })
  assert.deepEqual(restoration({ shownListQuery: afterFilter, address: at("?type=all&search=y&document_id=D&preview=V"), groups }),
    { kind: "frame", selection: { param: "document_id", id: "D" }, preview: { param: "preview", id: "V" } })
})

test("a page-mode parameter that came after the page rendered changes nothing", () => {
  const list = shown("?type=all")
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&viewport=desktop&document_id=D"), groups }).kind, "frame")
})

test("a form state and a page turn are page states; a repeated filter value counts whole", () => {
  const list = shown("?type=all")
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&new=document"), groups }), { kind: "page" })
  assert.deepEqual(restoration({ shownListQuery: list, address: at("?type=all&page=2"), groups }), { kind: "page" })
  const two = shown("?type=all&filter%5Btag%5D%5B%5D=a&filter%5Btag%5D%5B%5D=b")
  assert.deepEqual(restoration({ shownListQuery: two, address: at("?type=all&filter%5Btag%5D%5B%5D=b&filter%5Btag%5D%5B%5D=a&document_id=D"), groups }).kind, "frame")
  assert.deepEqual(restoration({ shownListQuery: two, address: at("?type=all&filter%5Btag%5D%5B%5D=a&document_id=D"), groups }).kind, "page")
})

test("a preview state restores through the wrapper's route with the ids filled in, without the document view", () => {
  const template = `/org/o1/projects/p1/documents/${SELECTION_PLACEHOLDER}/preview?version_id=${PREVIEW_PLACEHOLDER}`
  const state = { selection: { param: "document_id", id: "D" }, preview: { param: "preview", id: "V" } }
  assert.equal(previewAddress(template, state), "/org/o1/projects/p1/documents/D/preview?version_id=V")
  assert.equal(previewAddress(undefined, state), null)
  assert.equal(previewAddress(template, { selection: state.selection, preview: null }), null)
})

// Ticket relations (doc/ticket_relations_plan.md, revision 4, §8.2): a link from the lane of
// project A opens the page of project B. Back then pops A's entry while B's restorer listens.
// The query parts are alike (only ticket_id), so B took the entry for a lane change of its
// own; its page visit cancelled the one Turbo had just started for the same address and fell
// to the duplicate-request guard of application.js: the address said A, the page stayed B.
test("another page's entry: Turbo's own is left to Turbo, a lane entry of that page is a page", () => {
  const list = shown("")
  const other = new URL("http://x.test/org/o1/projects/p2/knowledge?document_id=D")

  assert.deepEqual(restoration({ shownPath: "/org/o1/projects/p1/knowledge", shownListQuery: list, address: other, groups, turboEntry: true }),
    { kind: "turbo" })
  assert.deepEqual(restoration({ shownPath: "/org/o1/projects/p1/knowledge", shownListQuery: list, address: other, groups, turboEntry: false }),
    { kind: "page" })
})

test("this page's own entries restore as before, Turbo's included", () => {
  const list = shown("")
  const own = at("?document_id=D")

  assert.equal(restoration({ shownPath: "/org/o1/projects/p1/knowledge", shownListQuery: list, address: own, groups, turboEntry: true }).kind, "frame")
  assert.equal(restoration({ shownListQuery: list, address: own, groups }).kind, "frame")
})

// "+" on "Alle Meetings" (new=meeting), then a search while the form is open: the list reload
// remembers its list part WITH the form state. Escape closes the lane and takes new out of the
// address, and nothing reloads the list. Back then pops new=meeting with that very list part,
// and the restorer took it for the closed lane: the address said "form", the lane stayed shut.
test("a form state over the list the page shows restores the page, so the form opens again", () => {
  const meetings = parseLaneParams(JSON.stringify({ selection: ["meeting_id"], form: ["new"], ignore: ["viewport"] }))
  const overview = (query) => new URL(`http://x.test/org/o1/meetings${query}`)
  const reloadedWithForm = listPart("?search=Alpha&new=meeting", meetings)

  assert.deepEqual(restoration({ shownListQuery: reloadedWithForm, address: overview("?search=Alpha&new=meeting"), groups: meetings }),
    { kind: "page" })
  assert.deepEqual(restoration({ shownListQuery: listPart("?search=Alpha", meetings), address: overview("?search=Alpha&new=meeting"), groups: meetings }),
    { kind: "page" })
  // No form in the address, the same list: the closed lane, as before.
  assert.deepEqual(restoration({ shownListQuery: listPart("?search=Alpha", meetings), address: overview("?search=Alpha"), groups: meetings }),
    { kind: "close" })
})
