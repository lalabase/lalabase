import { Controller } from "@hotwired/stimulus"
import { detailAddress } from "list_row/address"
import { readLaneParams, laneParamNames } from "lane/params"

// The preview root's width, and what it shows (D5 of doc/dateivorschau_plan.md):
// a PDF embed is mounted from its <template> once the root is at least
// minWidth wide, and unmounted once it is narrower than that by more than
// SLACK, where the text version stands in. The slack is against a loop: the
// embed brings a scrollbar, a classic scrollbar takes up to 17 px off the
// root, and a root that was just wide enough would unmount, lose the
// scrollbar, be wide enough again. The root itself is measured (a
// ResizeObserver), so the desktop lane and the phone's detail measure the
// same thing; a hidden iframe would load its file whether lazy or not (the
// spike), so below the width there is no iframe at all. 480 is the lane at a
// 1440 px window with a little room; a page of A4 is still readable there.
// Also the two small hands of the preview: "Aktualisieren" fetches the preview
// again, and an image the browser cannot decode steps aside for the download.
// The fetch is the frame's src when it has one (Turbo's reload of an unchanged
// src); a preview the PAGE rendered (a direct open, a reload, the phone) sits
// in a frame without a src, where reload() does nothing, so the root carries
// the preview's own road (refreshUrl) and the frame fetches that with the live
// query, as a lane link would; without a frame, the page.
const SLACK = 32

export default class extends Controller {
  static targets = ["template", "mount", "fallback", "image", "imageFallback"]
  static values = { minWidth: { type: Number, default: 480 }, refreshUrl: { type: String, default: "" } }

  connect() {
    if (!this.hasTemplateTarget) return
    this.mounted = false
    // The width as it is now, before the observer's first report: a resize
    // observer reports with the rendering steps, and a tab in the background
    // renders nothing until it is shown again.
    this.apply(this.element.getBoundingClientRect().width)
    if (typeof ResizeObserver === "undefined") return
    this.observer = new ResizeObserver((entries) => {
      for (const entry of entries) this.apply(entry.contentRect.width)
    })
    this.observer.observe(this.element)
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  apply(width) {
    const wide = this.mounted ? width >= this.minWidthValue - SLACK : width >= this.minWidthValue
    if (wide && !this.mounted) {
      this.mountTarget.replaceChildren(this.templateTarget.content.cloneNode(true))
      this.mounted = true
    } else if (!wide && this.mounted) {
      this.mountTarget.replaceChildren()
      this.mounted = false
    }
    this.mountTarget.hidden = !wide
    if (this.hasFallbackTarget) this.fallbackTarget.hidden = wide
  }

  refresh(event) {
    if (event) event.preventDefault()
    const frame = this.element.closest("turbo-frame")
    if (frame && frame.getAttribute("src")) {
      frame.reload()
      return
    }
    if (frame && this.refreshUrlValue) {
      const current = new URL(window.location.href)
      const params = laneParamNames(readLaneParams(this.element))
      frame.setAttribute("src", detailAddress({ url: this.refreshUrlValue, current, frame: frame.id, params }))
      return
    }
    window.Turbo.visit(window.location.href, { action: "replace" })
  }

  imageFailed() {
    if (this.hasImageTarget) this.imageTarget.hidden = true
    if (this.hasImageFallbackTarget) this.imageFallbackTarget.hidden = false
  }
}
