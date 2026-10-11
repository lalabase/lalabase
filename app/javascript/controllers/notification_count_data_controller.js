import { Controller } from "@hotwired/stimulus"

// Dispatches a global event whenever the unread count changes so
// multiple UI elements can stay in sync without requiring a full reload.
export default class extends Controller {
  static values = {
    count: Number,
  }

  connect() {
    this.dispatchUpdate()
  }

  countValueChanged() {
    this.dispatchUpdate()
  }

  dispatchUpdate() {
    const count = Number.isFinite(this.countValue) ? this.countValue : 0
    window.dispatchEvent(new CustomEvent("notifications:count-updated", { detail: { count } }))
  }
}
