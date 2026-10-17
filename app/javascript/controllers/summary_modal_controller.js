import { Controller } from "@hotwired/stimulus"

// Controller for the summary modal shown when there is no API key
export default class extends Controller {
  static targets = ["modal"]
  
  connect() {
    // Modal is hidden initially (hidden class in the HTML)
  }
  
  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }
  
  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }
  
  closeOnBackdrop(event) {
    // Only close when the backdrop was clicked
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