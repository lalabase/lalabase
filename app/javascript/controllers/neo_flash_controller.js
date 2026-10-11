import { Controller } from "@hotwired/stimulus"

// Neo Flash Controller
// Fades flash messages in and out (no slide) and handles auto-hide
export default class extends Controller {
  static values = {
    autoShow: Boolean,
    autoHide: Boolean,
    hideDelay: Number
  }

  // Fade-out runs slightly slower than the CSS fade-in (300ms) — reads calmer
  static HIDE_DURATION_MS = 500

  connect() {
    if (this.autoShowValue) {
      // Small delay to ensure the element is fully rendered
      requestAnimationFrame(() => {
        this.show()
      })
    }
  }

  show() {
    // Force a reflow so the opacity transition kicks in
    this.element.offsetHeight

    this.element.style.opacity = '1'

    // Auto-hide after delay if enabled
    if (this.autoHideValue && this.hideDelayValue > 0) {
      this.hideTimeout = setTimeout(() => {
        this.hide()
      }, this.hideDelayValue)
    }
  }

  hide() {
    // Clear any existing timeout
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
    }

    this.element.style.transitionDuration = `${this.constructor.HIDE_DURATION_MS}ms`
    this.element.style.transitionTimingFunction = 'ease-in'
    this.element.style.opacity = '0'

    // Remove the element once the fade-out finished; the timeout is the
    // fallback for when transitionend never fires (hidden tab, reduced motion)
    this.element.addEventListener('transitionend', () => this.element.remove(), { once: true })
    this.removeTimeout = setTimeout(() => {
      this.element.remove()
    }, this.constructor.HIDE_DURATION_MS + 100)
  }

  // User interaction to hide
  dismiss() {
    this.hide()
  }

  disconnect() {
    // Clean up timeouts on disconnect
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
    }
    if (this.removeTimeout) {
      clearTimeout(this.removeTimeout)
    }
  }
}
