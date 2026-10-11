import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="inline-status"
// Badge-style dropdown for inline status changes.
// Replaces native <select> with a badge button + dropdown menu.
export default class extends Controller {
  static targets = ["form", "menu", "badge", "hiddenField"]

  connect() {
    this.closeOnClickOutside = this.closeOnClickOutside.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
  }

  toggle(event) {
    event.stopPropagation()
    if (this.hasMenuTarget) {
      const isOpen = !this.menuTarget.classList.contains("hidden")
      isOpen ? this.close() : this.open()
    }
  }

  open() {
    if (!this.hasMenuTarget) return
    this.menuTarget.classList.remove("hidden")
    document.addEventListener("click", this.closeOnClickOutside)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  close() {
    if (!this.hasMenuTarget) return
    this.menuTarget.classList.add("hidden")
    document.removeEventListener("click", this.closeOnClickOutside)
    document.removeEventListener("keydown", this.closeOnEscape)
  }

  select(event) {
    const value = event.currentTarget.dataset.value
    if (this.hasHiddenFieldTarget) {
      this.hiddenFieldTarget.value = value
    }
    this.close()
    if (this.hasFormTarget) {
      this.formTarget.requestSubmit()
    }
  }

  // Legacy: auto-submit when native select changes (fallback)
  submit() {
    if (this.hasFormTarget) {
      this.formTarget.requestSubmit()
    } else {
      this.element.requestSubmit()
    }
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnClickOutside)
    document.removeEventListener("keydown", this.closeOnEscape)
  }
}
