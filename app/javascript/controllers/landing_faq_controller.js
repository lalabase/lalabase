import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "panel", "icon"]

  toggle(event) {
    const button = event.currentTarget
    const index = this.itemTargets.indexOf(button)
    if (index === -1) return

    const panel = this.panelTargets[index]
    const icon = this.iconTargets[index]
    const isOpen = !panel.classList.contains("hidden")

    if (isOpen) {
      panel.classList.add("hidden")
      icon.classList.remove("rotate-45")
      button.setAttribute("aria-expanded", "false")
    } else {
      panel.classList.remove("hidden")
      icon.classList.add("rotate-45")
      button.setAttribute("aria-expanded", "true")
    }
  }
}
