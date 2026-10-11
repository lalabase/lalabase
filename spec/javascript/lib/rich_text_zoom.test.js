// What: which click inside a rendered rich text opens the lightbox.
// Type: node:test unit spec (no DOM library; a tiny element stub mimics closest/contains).
// Why: the controller is delegated on the content wrapper because ActionText strips data
//   attributes from the attachment partials; this function is the whole decision.
import { test } from "node:test"
import assert from "node:assert/strict"
import { zoomLinkFor } from "../../../app/javascript/lib/rich_text_zoom.js"

function element({ zoomLink = null, insideRoot = true } = {}) {
  const link = zoomLink ? { tag: "a.attachment__zoom" } : null
  const root = { contains: () => insideRoot }
  const target = { closest: (selector) => (selector === "a.attachment__zoom" ? link : null) }
  return { target, root, link }
}

test("returns the zoom link for a click on the image inside it", () => {
  const { target, root, link } = element({ zoomLink: true })
  assert.equal(zoomLinkFor(target, root), link)
})

test("ignores clicks outside a zoom link", () => {
  const { target, root } = element({ zoomLink: false })
  assert.equal(zoomLinkFor(target, root), null)
})

test("ignores zoom links outside the controller's root (nested wrappers)", () => {
  const { target, root } = element({ zoomLink: true, insideRoot: false })
  assert.equal(zoomLinkFor(target, root), null)
})

test("leaves modifier clicks (new tab) to the browser", () => {
  const { target, root } = element({ zoomLink: true })
  assert.equal(zoomLinkFor(target, root, { metaKey: true }), null)
  assert.equal(zoomLinkFor(target, root, { ctrlKey: true }), null)
})

test("tolerates a non-element target", () => {
  assert.equal(zoomLinkFor(null, null), null)
  assert.equal(zoomLinkFor({}, null), null)
})
