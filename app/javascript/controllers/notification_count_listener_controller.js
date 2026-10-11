import { Controller } from "@hotwired/stimulus"

// Keeps any element aligned with the latest unread notification count.
// Listen for the global `notifications:count-updated` event and update
// label content, visibility indicators, and aria attributes as needed.
export default class extends Controller {
  static targets = ["label", "indicator"]

  static values = {
    count: Number,
    zeroLabel: String,
    oneLabel: String,
    otherLabel: String,
    includeCount: { type: Boolean, default: true },
  }

  connect() {
    this.applyCount(this.countValue ?? 0)
    this._handleUpdate = (event) => {
      const nextCount = event.detail?.count ?? 0
      if (this.countValue !== nextCount) {
        this.countValue = nextCount
      } else {
        this.applyCount(nextCount)
      }
    }
    window.addEventListener("notifications:count-updated", this._handleUpdate)
  }

  disconnect() {
    window.removeEventListener("notifications:count-updated", this._handleUpdate)
  }

  countValueChanged() {
    this.applyCount(this.countValue ?? 0)
  }

  applyCount(count) {
    this.setLabel(count)
    this.toggleIndicator(count)
    this.updateAria(count)
  }

  setLabel(count) {
    if (!this.hasLabelTarget) return
    const base = this.labelFor(count)
    const text = this.includeCountValue && count > 0 ? `${base} (${count})` : base
    this.labelTarget.textContent = text
  }

  toggleIndicator(count) {
    if (!this.hasIndicatorTarget) return
    this.indicatorTarget.classList.toggle("hidden", !(count > 0))
    this.indicatorTarget.textContent = count > 99 ? '99+' : count
  }

  updateAria(count) {
    const base = this.labelFor(count)
    const text = this.includeCountValue && count > 0 ? `${base} (${count})` : base
    if (this.element instanceof HTMLElement) {
      if (this.element.hasAttribute("aria-label")) {
        this.element.setAttribute("aria-label", text.trim())
      }
    }
  }

  labelFor(count) {
    if (count === 0) return this.zeroLabelValue || ""
    if (count === 1) return this.oneLabelValue || this.zeroLabelValue || ""
    return this.otherLabelValue || this.zeroLabelValue || ""
  }
}
