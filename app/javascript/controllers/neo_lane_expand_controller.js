import { Controller } from "@hotwired/stimulus"

// Capped list with inline expand toggle.
// Items beyond `thresholdValue` carry the "hidden" class server-rendered;
// clicking the toggle reveals/hides them and swaps the button label.
export default class extends Controller {
  static targets = ["item", "button"]
  static values = { threshold: { type: Number, default: 10 } }

  connect() {
    this.expanded = false
  }

  toggle(event) {
    event.preventDefault()
    this.expanded = !this.expanded

    this.itemTargets.forEach((item, index) => {
      if (index >= this.thresholdValue) {
        item.classList.toggle("hidden", !this.expanded)
      }
    })

    if (this.hasButtonTarget) {
      const { collapsedLabel, expandedLabel } = this.buttonTarget.dataset
      this.buttonTarget.textContent = this.expanded ? expandedLabel : collapsedLabel
    }
  }
}
