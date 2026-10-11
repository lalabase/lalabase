import { Controller } from "@hotwired/stimulus"
import { isOpen, remember } from "expanded_rows"

// Expands and collapses the bookings under one row of the time list. Folded by
// default: the workflow is preparing a billing, not reading every booking.
//
// An open row survives a reload. Assigning a selection to a billing answers with
// a redirect, and without this the rows the reader had just opened to decide
// what to select would all fold away again. lib/expanded_rows.js owns where that
// is kept; `expand_all` from the address still wins over it.
export default class extends Controller {
  static targets = ["sessions", "chevron", "title"]
  static values  = { expanded: Boolean, key: String }

  connect() {
    if (!this.expandedValue && isOpen(this.storage, this.path, this.keyValue)) {
      this.expandedValue = true
    }
    this.apply()
  }

  toggle(event) {
    // Clicks on checkboxes, links or other buttons within the header
    // should NOT toggle — the chevron button carries data-toggle-allowed
    // and lets the click through (via bubbling to the header action).
    if (event.target.closest('input, a, button:not([data-toggle-allowed]), [data-no-toggle]')) return
    this.expandedValue = !this.expandedValue
    remember(this.storage, this.path, this.keyValue, this.expandedValue)
    this.apply()
  }

  apply() {
    if (!this.hasSessionsTarget) return
    if (this.expandedValue) {
      this.sessionsTarget.classList.remove("hidden")
      if (this.hasChevronTarget) this.chevronTarget.classList.add("rotate-90")
    } else {
      this.sessionsTarget.classList.add("hidden")
      if (this.hasChevronTarget) this.chevronTarget.classList.remove("rotate-90")
    }
    // The state for a screen reader. The chevron only ROTATES, and the button's
    // label is the count, so without this the button never says open or closed.
    this.element.querySelectorAll("[data-toggle-allowed]").forEach(button => {
      button.setAttribute("aria-expanded", String(this.expandedValue))
    })
  }

  get storage() {
    // Reading the property itself can throw where site data is blocked.
    try { return window.sessionStorage } catch { return null }
  }

  get path() {
    return window.location.pathname
  }
}
