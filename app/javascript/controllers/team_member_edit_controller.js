import { Controller } from "@hotwired/stimulus"

// Toggles a member row between its pre-rendered view row and edit row (no server
// fetch, no GET-edit route) and only enables Save once a level actually changes.
export default class extends Controller {
  static targets = ["viewRow", "editRow", "saveButton"]

  open() {
    this.viewRowTarget.classList.add("hidden")
    this.editRowTarget.classList.remove("hidden")
  }

  close() {
    this.editRowTarget.classList.add("hidden")
    this.viewRowTarget.classList.remove("hidden")
  }

  markDirty() {
    if (!this.hasSaveButtonTarget) return
    this.saveButtonTarget.disabled = false
    this.saveButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
  }
}
