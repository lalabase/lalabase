import { Controller } from "@hotwired/stimulus"

// Failed requests leave the entire form, including target and title, in place.
export default class extends Controller {
  static targets = ["form", "disclosure", "error", "success", "message", "link"]
  static values = { error: String }

  revise(event) {
    const { answerId: id, answerKey: key, chatId } = event.currentTarget.dataset
    this.element.dispatchEvent(new CustomEvent("assistant:revise", { bubbles: true, detail: { id, key, chatId } }))
  }

  cancel() { this.disclosureTarget.open = false }

  reveal() {
    if (this.disclosureTarget.open) this.formTarget.scrollIntoView({ block: "nearest" })
  }

  async save(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.saving) return
    this.saving = true
    const button = this.formTarget.querySelector('[type="submit"]')
    button.disabled = true
    this.errorTarget.textContent = ""
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST", body: new FormData(this.formTarget),
        headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      })
      if (!response.headers.get("content-type")?.includes("application/json")) throw new Error(this.errorValue)
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || this.errorValue)
      this.messageTarget.textContent = result.message
      this.linkTarget.href = result.url
      this.disclosureTarget.hidden = true
      this.successTarget.hidden = false
      // The meeting page may be open behind the panel; its stored-analyses section
      // listens for this and fetches its own authorized rendering.
      if (result.meeting_id) {
        window.dispatchEvent(new CustomEvent("assistant:analyses-changed", { detail: { meetingId: result.meeting_id } }))
      }
    } catch (error) {
      this.errorTarget.textContent = error.message || this.errorValue
    } finally {
      this.saving = false
      button.disabled = false
    }
  }
}
