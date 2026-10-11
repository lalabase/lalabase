import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["image", "initials"]

  connect() {
    if (this.hasImageTarget && this.imageTarget.complete && this.imageTarget.naturalWidth === 0) this.showInitials()
  }

  showInitials() {
    this.imageTarget.hidden = true
    this.initialsTarget.hidden = false
  }
}
