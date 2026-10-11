import { Controller } from "@hotwired/stimulus"

// Reveals the element only after a referenced turbo-frame has finished loading.
// Used to keep secondary UI (e.g. "new comment" buttons) out of the layout flow
// until the lazy-loaded timeline frame above has settled — prevents visible
// re-flow / "jumping" of the buttons.
//
// Usage:
//   <div class="hidden"
//        data-controller="reveal-after-frame"
//        data-reveal-after-frame-frame-id-value="ticket-timeline-123">
export default class extends Controller {
  static values = { frameId: String }

  connect() {
    const frame = document.getElementById(this.frameIdValue)
    if (!frame) {
      this.reveal()
      return
    }

    if (this.frameAlreadyLoaded(frame)) {
      this.reveal()
      return
    }

    this.handler = () => this.reveal()
    frame.addEventListener("turbo:frame-load", this.handler, { once: true })
  }

  disconnect() {
    if (this.handler) {
      const frame = document.getElementById(this.frameIdValue)
      frame?.removeEventListener("turbo:frame-load", this.handler)
    }
  }

  frameAlreadyLoaded(frame) {
    // A loaded frame has rendered content (not just an empty shell)
    return frame.children.length > 0 && !frame.hasAttribute("busy")
  }

  reveal() {
    this.element.classList.remove("hidden")
    this.element.classList.add("timeline-secondary-reveal")
  }
}
