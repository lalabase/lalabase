import { Controller } from "@hotwired/stimulus"

// Simple tabs: toggles `data-active` on tabs and `hidden` on panels.
// Style active/inactive via Tailwind `data-[active=true]:*` modifiers in markup.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { param: { type: String, default: "tab" } }

  connect() {
    const param = new URLSearchParams(window.location.search).get(this.paramValue)
    if (param) {
      const index = this.tabTargets.findIndex(t => t.dataset.tabId === param)
      if (index > -1) {
        this.#activate(index)
        return
      }
    }
    // Default to first tab if no URL param
    const initial = this.tabTargets.findIndex(t => t.dataset.active === "true")
    this.#activate(initial > -1 ? initial : 0)
  }

  switch(event) {
    const index = this.tabTargets.indexOf(event.currentTarget)
    this.#activate(index)
  }

  #activate(index) {
    this.tabTargets.forEach((tab, i) => {
      tab.dataset.active = (i === index).toString()
    })
    this.panelTargets.forEach((panel, i) => {
      panel.classList.toggle("hidden", i !== index)
    })
  }
}
