import { Controller } from "@hotwired/stimulus"

// Mobile filter drawer: the filter section is hidden by default on mobile
// and is shown/hidden via a "Filter" trigger button. On desktop
// (lg+) the section is always visible.
export default class extends Controller {
  static targets = ["drawer", "backdrop"]

  open() {
    if (this.hasDrawerTarget) this.drawerTarget.classList.remove("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden", "lg:overflow-auto")
  }

  close() {
    if (this.hasDrawerTarget) this.drawerTarget.classList.add("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  toggle() {
    if (!this.hasDrawerTarget) return
    if (this.drawerTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }
}
