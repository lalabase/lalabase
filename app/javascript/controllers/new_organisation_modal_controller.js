import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "form"]

  connect() {
    this.modalTarget.classList.add("hidden")
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")

    const input = this.modalTarget.querySelector("input[type='text']")
    if (input) input.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")

    if (this.hasFormTarget) {
      const form = this.formTarget.querySelector("form")
      if (form) {
        form.reset()
        const errors = this.formTarget.querySelectorAll(".new-organisation-error-container")
        errors.forEach(error => error.remove())
      }
    }
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) {
      this.close()
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasModalTarget && !this.modalTarget.classList.contains("hidden")
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && this.ownsEscape()) {
      this.close()
    }
  }
}
