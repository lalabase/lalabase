import { Controller } from "@hotwired/stimulus"

// Controls the collapsible ticket description in the detail view.
//
// Expanding/collapsing is a purely client-side display toggle (no server
// round-trip, no preference change — the user can always peek). The one-time
// info box, however, persists the global preference: "auto" keeps collapsing
// silently from now on, "always_full" opts out and expands the current ticket.
// Both answers PATCH /user_preferences and then remove the info box.
export default class extends Controller {
  static targets = ["body", "attachments", "collapsedControls", "expandedControls", "infobox"]
  static values = { updateUrl: String }

  expand() {
    this.#setCollapsed(false)
  }

  collapse() {
    this.#setCollapsed(true)
  }

  // "So übernehmen" — keep collapsing, stop asking.
  accept() {
    this.#savePreference("auto")
    this.#removeInfobox()
  }

  // "Immer die ganze Beschreibung anzeigen" — opt out and show it now.
  alwaysFull() {
    this.#savePreference("always_full")
    this.#setCollapsed(false)
    this.#removeInfobox()
  }

  #setCollapsed(collapsed) {
    this.bodyTarget.classList.toggle("line-clamp-2", collapsed)
    if (this.hasAttachmentsTarget) this.attachmentsTarget.classList.toggle("hidden", collapsed)
    this.collapsedControlsTarget.classList.toggle("hidden", !collapsed)
    if (this.hasExpandedControlsTarget) this.expandedControlsTarget.classList.toggle("hidden", collapsed)
    // The info box only makes sense while collapsed (it explains the collapse).
    if (this.hasInfoboxTarget) this.infoboxTarget.classList.toggle("hidden", !collapsed)
  }

  #removeInfobox() {
    if (this.hasInfoboxTarget) this.infoboxTarget.remove()
  }

  async #savePreference(value) {
    if (!this.hasUpdateUrlValue) return

    const csrf = document.querySelector("meta[name='csrf-token']")?.content

    try {
      await fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrf,
          "Accept": "application/json"
        },
        body: JSON.stringify({
          preferences: { description_collapse: value }
        })
      })
    } catch (error) {
      console.error("Description collapse preference save failed:", error)
    }
  }
}
