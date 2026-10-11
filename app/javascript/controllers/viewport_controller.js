import { Controller } from "@hotwired/stimulus"
// Bare specifier, NEVER a relative "../lib/breakpoints" import: relative paths bypass
// importmap resolution and 404 on the undigested URL in production.
import { MOBILE_BREAKPOINT } from "breakpoints"

// Switches between mobile and desktop layout by reloading the page with the appropriate viewport param
export default class extends Controller {
  static values = {
    // Overridable per view via data-viewport-breakpoint-value, but no view does — they all
    // wanted the default. Set the attribute only for a genuinely different boundary.
    breakpoint: { type: Number, default: MOBILE_BREAKPOINT },
    currentMode: { type: String, default: "desktop" },
    debounce: { type: Number, default: 200 }
  }

  connect() {
    this.handleResize = this.handleResize.bind(this)
    this.pending = null
    this.pendingTarget = null
    window.addEventListener("resize", this.handleResize)
    this._maybeSwitch()
  }

  disconnect() {
    window.removeEventListener("resize", this.handleResize)
    if (this.pending) {
      clearTimeout(this.pending)
      this.pending = null
      this.pendingTarget = null
    }
  }

  handleResize() {
    this._maybeSwitch()
  }

  _maybeSwitch() {
    const actual = this._detectState()
    if (actual === this.currentModeValue || actual === this.pendingTarget) {
      return
    }

    if (this.pending) {
      clearTimeout(this.pending)
    }

    this.pendingTarget = actual
    this.pending = setTimeout(() => {
      const url = new URL(window.location.href)
      url.searchParams.set('viewport', actual)
      if (window.Turbo) {
        window.Turbo.visit(url.toString(), { action: 'replace' })
      } else {
        window.location.href = url.toString()
      }
    }, this.debounceValue)
  }

  _detectState() {
    return window.innerWidth < this.breakpointValue ? 'mobile' : 'desktop'
  }
}
