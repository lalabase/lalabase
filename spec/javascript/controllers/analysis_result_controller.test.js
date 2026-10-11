import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../../app/javascript/controllers/analysis_result_controller.js", import.meta.url), "utf8")
  .replace(/^import .*\n/gm, "")
  .replace("export default class", "class AnalysisResultController")

function fixture(href) {
  let location = new URL(href, "https://lalabase.test")
  let preview = false
  let viewport = null
  let scrolls = 0
  const details = { open: false }
  const Controller = runInNewContext(`${source}\nAnalysisResultController`, {
    Controller: class {}, URL, MOBILE_BREAKPOINT: 768,
    document: { documentElement: { hasAttribute: () => preview } },
    window: {
      innerWidth: 390,
      location: { get href() { return location.href } },
      history: { state: { turbo: true }, replaceState: (_state, _title, url) => { location = new URL(url) } }
    }
  })
  const controller = new Controller()
  controller.element = { closest: () => viewport, dataset: { analysisId: "a1" }, querySelector: () => details, scrollIntoView: () => scrolls++ }
  return { controller, details, setViewport: value => { viewport = value }, setPreview: value => { preview = value }, get location() { return location }, get scrolls() { return scrolls } }
}

test("the cache preview preserves the deep link for the final page, which consumes it once", () => {
  const f = fixture("/meetings/m1?analysis_id=a1&filter=current#meeting_analysis_a1")
  f.setPreview(true)
  f.controller.connect()
  assert.equal(f.details.open, false)
  assert.equal(f.location.searchParams.get("analysis_id"), "a1")
  f.setPreview(false)
  f.controller.connect()
  assert.equal(f.details.open, true)
  assert.equal(f.scrolls, 1)
  assert.equal(f.location.searchParams.get("filter"), "current")
  assert.equal(f.location.searchParams.has("analysis_id"), false)
  f.details.open = false
  f.controller.connect()
  assert.equal(f.details.open, false)
  assert.equal(f.scrolls, 1)
})

test("another result does not consume the requested result's link", () => {
  const f = fixture("/meetings/m1?analysis_id=a2")
  f.controller.connect()
  assert.equal(f.details.open, false)
  assert.equal(f.location.searchParams.get("analysis_id"), "a2")
})

test("the preliminary desktop render on a phone leaves the link for the mobile replacement", () => {
  const f = fixture("/meetings/m1?analysis_id=a1")
  const viewport = { dataset: { viewportCurrentModeValue: "desktop" } }
  f.setViewport(viewport)
  f.controller.connect()
  assert.equal(f.details.open, false)
  assert.equal(f.location.searchParams.get("analysis_id"), "a1")
  viewport.dataset.viewportCurrentModeValue = "mobile"
  f.controller.connect()
  assert.equal(f.details.open, true)
  assert.equal(f.location.searchParams.has("analysis_id"), false)
})
