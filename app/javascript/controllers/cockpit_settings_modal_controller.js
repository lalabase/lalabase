import { Controller } from "@hotwired/stimulus"

// Cockpit settings modal. Mirrors new_organisation_modal (open/close/ESC/backdrop) and adds two
// things: focus restore to the trigger on close (a11y), and disabling the importance radios while
// the "show actions" checkbox is off (they only matter when the action area is shown). A minimal
// Tab focus-trap keeps keyboard focus inside the open modal (same idea as personal_tasks_drawer).
export default class extends Controller {
  static targets = ["modal", "showActions", "importance"]

  connect() {
    this.modalTarget.classList.add("hidden")
    this.syncImportanceEnabled()
  }

  open() {
    this.previouslyFocused = document.activeElement
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.syncImportanceEnabled()
    const focusable = this.modalTarget.querySelector("input, button, select, [tabindex]")
    if (focusable) focusable.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    if (this.previouslyFocused && this.previouslyFocused.focus) this.previouslyFocused.focus()
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) this.close()
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.modalTarget.classList.contains("hidden")) this.close()
  }

  // Grey out + disable the importance radios while "show actions" is unchecked.
  syncImportanceEnabled() {
    if (!this.hasShowActionsTarget) return

    const enabled = this.showActionsTarget.checked
    this.importanceTargets.forEach((radio) => {
      radio.disabled = !enabled
    })
    const row = this.element.querySelector("[data-importance-row]")
    if (row) row.classList.toggle("opacity-50", !enabled)
  }

  // Minimal focus trap: keep Tab focus inside the modal while it is open.
  trapFocus(event) {
    if (event.key !== "Tab" || this.modalTarget.classList.contains("hidden")) return

    const focusables = this.modalTarget.querySelectorAll(
      "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
    )
    if (focusables.length === 0) return

    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }
}
