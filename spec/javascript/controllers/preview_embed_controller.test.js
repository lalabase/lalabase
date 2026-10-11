// What: preview_embed_controller, the PDF embed that exists only while the
//   preview root is wide enough (D5 of doc/dateivorschau_plan.md).
// Type: node:test over the controller's source in a vm context, against fakes
//   of the targets and a ResizeObserver that reports what the test says.
// Why: a hidden iframe loads its file whether lazy or not (the spike), so
//   below the width there must be NO iframe in the document, and the text
//   version stands in; above it the template is mounted once and not again,
//   and a root the embed's own scrollbar made a little narrower keeps it.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/preview_embed_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class PreviewEmbedController")

function fixture({ withTemplate = true } = {}) {
  let callback
  class ResizeObserver {
    constructor(fn) { callback = fn }
    observe() {}
    disconnect() { this.disconnected = true }
  }
  const window = { location: { href: "http://lalabase.test/org/o1/projects/p1/knowledge?type=all&document_id=D&preview=V" }, Turbo: { visit: (url, options) => visits.push([url, options]) } }
  const visits = []
  const Controller = runInNewContext(`${source}\nPreviewEmbedController`, {
    Controller: class {}, ResizeObserver, window, URL,
    detailAddress: ({ url, current, frame, params }) => `detail(${url}|${current.search}|${frame}|${params.join(",")})`,
    readLaneParams: () => ({ selection: ["note_id", "document_id"], preview: ["preview"], form: ["new"], ignore: ["viewport"] }),
    laneParamNames: (groups) => [...groups.selection, ...groups.preview]
  })
  const controller = new Controller()
  const mount = { children: [], hidden: false, replaceChildren(...nodes) { this.children = nodes } }
  const fallback = { hidden: false }
  const clones = []
  controller.element = { getBoundingClientRect: () => ({ width: 0 }), closest: () => null }
  controller.hasTemplateTarget = withTemplate
  controller.templateTarget = { content: { cloneNode: () => { const node = { iframe: true }; clones.push(node); return node } } }
  controller.mountTarget = mount
  controller.hasFallbackTarget = true
  controller.fallbackTarget = fallback
  controller.minWidthValue = 560
  controller.connect()
  const resize = (width) => callback([{ contentRect: { width } }])
  return { controller, mount, fallback, clones, resize, visits }
}

test("on connect the width as it is now decides, before the observer reports", () => {
  const { mount, fallback, clones } = fixture()
  assert.equal(mount.hidden, true, "a root with no width yet shows the fallback")
  assert.equal(fallback.hidden, false)
  assert.equal(clones.length, 0)
})

test("narrow: no iframe in the document, the text fallback shown", () => {
  const { mount, fallback, clones, resize } = fixture()
  resize(400)
  assert.deepEqual(mount.children, [])
  assert.equal(mount.hidden, true)
  assert.equal(fallback.hidden, false)
  assert.equal(clones.length, 0)
})

test("wide: the template is mounted once, the fallback hidden; wider again mounts nothing new", () => {
  const { mount, fallback, clones, resize } = fixture()
  resize(700)
  assert.equal(mount.children.length, 1)
  assert.equal(mount.hidden, false)
  assert.equal(fallback.hidden, true)
  resize(900)
  assert.equal(clones.length, 1)
})

test("narrow after wide unmounts the iframe and brings the text back", () => {
  const { mount, fallback, resize } = fixture()
  resize(700)
  resize(500)
  assert.deepEqual(mount.children, [])
  assert.equal(fallback.hidden, false)
})

test("a mounted embed survives the width a classic scrollbar takes, so it cannot mount and unmount in a loop", () => {
  const { mount, clones, resize } = fixture()
  resize(560)
  assert.equal(mount.children.length, 1, "exactly wide enough mounts")
  resize(543)
  assert.equal(mount.children.length, 1, "17 px narrower, the scrollbar's width, keeps the embed")
  resize(527)
  assert.deepEqual(mount.children, [], "past the slack it unmounts")
  resize(543)
  assert.deepEqual(mount.children, [], "and does not mount again below the width")
  resize(560)
  assert.equal(clones.length, 2)
})

test("without a template (an image, a text) the controller observes nothing", () => {
  const { controller } = fixture({ withTemplate: false })
  assert.equal(controller.observer, undefined)
})

test("refresh reloads the lane's frame and an undecodable image steps aside", () => {
  const { controller } = fixture()
  let reloaded = 0
  controller.element.closest = (selector) => (selector === "turbo-frame" ? { reload: () => reloaded++, getAttribute: () => "/documents/D/preview?frame=content" } : null)
  controller.refresh({ preventDefault: () => {} })
  assert.equal(reloaded, 1)
  controller.hasImageTarget = true
  controller.imageTarget = { hidden: false }
  controller.hasImageFallbackTarget = true
  controller.imageFallbackTarget = { hidden: true }
  controller.imageFailed()
  assert.equal(controller.imageTarget.hidden, true)
  assert.equal(controller.imageFallbackTarget.hidden, false)
})

test("refresh of a preview the page rendered: the frame has no src, so it fetches the preview's own road with the live query", () => {
  const { controller } = fixture()
  const frame = { id: "knowledge_display_frame", src: null, reload: () => { throw new Error("reload() of a frame without a src does nothing") }, getAttribute: () => null, setAttribute: (name, value) => { frame.src = value } }
  controller.element.closest = (selector) => (selector === "turbo-frame" ? frame : null)
  controller.refreshUrlValue = "/org/o1/projects/p1/documents/D/preview?version_id=V"
  controller.refresh({ preventDefault: () => {} })
  assert.equal(frame.src, "detail(/org/o1/projects/p1/documents/D/preview?version_id=V|?type=all&document_id=D&preview=V|knowledge_display_frame|note_id,document_id,preview)")
})

test("refresh without a frame around the preview visits the page again in place", () => {
  const { controller, visits } = fixture()
  controller.element.closest = () => null
  controller.refresh({ preventDefault: () => {} })
  assert.equal(visits.length, 1)
  assert.equal(visits[0][0], "http://lalabase.test/org/o1/projects/p1/knowledge?type=all&document_id=D&preview=V")
  assert.equal(visits[0][1].action, "replace")
})
