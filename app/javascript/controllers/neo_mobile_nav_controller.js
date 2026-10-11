import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["navigation", "actions", "edit"]
  static values = { editLabel: String }
  selectionChanged(event) {
    const { count, mobileActive } = event.detail
    this.navigationTarget.hidden = Boolean(mobileActive)
    this.actionsTarget.hidden = !mobileActive
    this.editTarget.disabled = count === 0
    this.editTarget.textContent = this.editLabelValue.replace("%{count}", count)
  }
  edit() { window.dispatchEvent(new CustomEvent("mobile-selection:edit")) }
  more() { window.dispatchEvent(new CustomEvent("mobile-selection:edit", { detail: { more: true } })) }
}
