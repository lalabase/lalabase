import { Controller } from "@hotwired/stimulus"
import { MOBILE_BREAKPOINT } from "breakpoints"

// A direct saved-result link opens precisely that row after Turbo renders the meeting.
export default class extends Controller {
  connect() {
    // A Turbo cache preview is replaced by the final response. Consuming the
    // address there would leave the actual result closed on the second render.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    // Direct links can initially render the desktop layout on a phone. The
    // viewport controller replaces that page; let the final layout consume it.
    const viewport = this.element.closest('[data-controller~="viewport"]')
    if (viewport) {
      const breakpoint = Number(viewport.dataset.viewportBreakpointValue) || MOBILE_BREAKPOINT
      const mode = window.innerWidth < breakpoint ? "mobile" : "desktop"
      if (viewport.dataset.viewportCurrentModeValue !== mode) return
    }
    const url = new URL(window.location.href)
    if (url.searchParams.get("analysis_id") !== this.element.dataset.analysisId) return
    const details = this.element.querySelector("details")
    if (details) details.open = true
    this.element.scrollIntoView({ block: "nearest" })
    url.searchParams.delete("analysis_id")
    url.hash = ""
    window.history.replaceState(window.history.state, "", url)
  }
}
