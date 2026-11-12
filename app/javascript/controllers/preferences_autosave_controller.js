import { Controller } from "@hotwired/stimulus"

// One section of the preferences page (user_preferences/_section): a change to any
// field saves the section's form at once and says so beside the heading. There is no
// button to forget at the end of a long page.
//
// The form stays an ordinary one. It is sent as it would submit itself (same fields,
// same token, same `current_section`), only with a JSON answer asked for; without
// JavaScript its <noscript> button sends it.
//
// The server may answer `reload: true`: the page the reader looks at is stale then
// (another language, another session length in the layout), and it is loaded again.
//
// One request at a time: a change made while a save is on its way is saved right
// after it, with the form as it stands then. The last state always wins.
export default class extends Controller {
  static targets = ["form", "status"]
  static values = { saved: String, failed: String }

  // How long "saved" stays beside the heading. A failure stays until the next save.
  static SAVED_VISIBLE_MS = 3000

  disconnect() {
    clearTimeout(this.clearTimer)
  }

  save() {
    if (this.saving) {
      this.again = true
      return
    }

    const form = this.formTarget
    // A field the page itself refuses (a date format with unknown codes) is not sent.
    if (!form.checkValidity()) {
      form.reportValidity()
      this.#show(this.failedValue, false)
      return
    }

    this.saving = true
    fetch(form.action, {
      method: "POST",
      body: new FormData(form),
      headers: { "Accept": "application/json" },
      credentials: "same-origin"
    })
      .then(async (response) => {
        const answer = await response.json().catch(() => ({}))
        if (!response.ok || !answer.success) throw new Error((answer.errors || []).join(", "))

        if (answer.reload) {
          window.location.reload()
          return
        }
        this.#show(this.savedValue, true)
      })
      .catch((error) => {
        this.#show([this.failedValue, error.message].filter(Boolean).join(": "), false)
      })
      .finally(() => {
        this.saving = false
        if (this.again) {
          this.again = false
          this.save()
        }
      })
  }

  #show(text, saved) {
    if (!this.hasStatusTarget) return

    clearTimeout(this.clearTimer)
    const icon = document.createElement("i")
    icon.className = saved ? "bi bi-check2 mr-1" : "bi bi-exclamation-triangle mr-1"
    icon.setAttribute("aria-hidden", "true")

    const status = this.statusTarget
    status.replaceChildren(icon, document.createTextNode(text))
    status.classList.toggle("text-muted", saved)
    status.classList.toggle("text-red-700", !saved)
    status.dataset.state = saved ? "saved" : "failed"

    if (saved) {
      this.clearTimer = setTimeout(() => {
        status.replaceChildren()
        delete status.dataset.state
      }, this.constructor.SAVED_VISIBLE_MS)
    }
  }
}
