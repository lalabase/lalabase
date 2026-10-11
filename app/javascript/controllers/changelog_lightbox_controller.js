import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "image"]

  open(event) {
    event.preventDefault()
    const src = event.params.src
    if (!src) return

    this.imageTarget.src = src
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    document.body.classList.add("overflow-hidden")
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
    document.body.classList.remove("overflow-hidden")
  }

  // Close on Escape key
  keydown(event) {
    if (event.key === "Escape") this.close()
  }
}
