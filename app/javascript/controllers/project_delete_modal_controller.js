import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "nameInput", "submitButton", "projectNameDisplay"]

  connect() {
    this.requiredName = ""
    this.deleteUrl = ""
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("keydown", this.boundCloseOnEscape)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundCloseOnEscape)
  }

  open(event) {
    // The name is read from the raw attribute, not from event.params: Stimulus
    // typecasts params through JSON.parse, so a project named `null`, `1.5` or
    // `"Kunde"` would arrive as something other than its own text and could
    // never be confirmed. A name is any text since the character rule went.
    const projectName = event.currentTarget.dataset.projectDeleteModalProjectNameParam ?? ""
    const { deleteUrl } = event.params
    // NFC on both sides: the model stores names composed, but a legacy row may
    // still be decomposed, and what a keyboard types is composed.
    this.requiredName = projectName.normalize("NFC")
    this.deleteUrl = deleteUrl

    this.projectNameDisplayTarget.textContent = projectName
    this.nameInputTarget.value = ""
    this.submitButtonTarget.disabled = true

    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.nameInputTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    this.nameInputTarget.value = ""
    this.submitButtonTarget.disabled = true
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

  typedName() {
    return this.nameInputTarget.value.trim().normalize("NFC")
  }

  validate() {
    this.submitButtonTarget.disabled = this.typedName() !== this.requiredName
  }

  confirmDelete() {
    if (this.typedName() !== this.requiredName) return

    // Create and submit a form with Turbo method DELETE
    const form = document.createElement("form")
    form.method = "POST"
    form.action = this.deleteUrl
    form.style.display = "none"

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (csrfToken) {
      const csrfInput = document.createElement("input")
      csrfInput.type = "hidden"
      csrfInput.name = "authenticity_token"
      csrfInput.value = csrfToken
      form.appendChild(csrfInput)
    }

    const methodInput = document.createElement("input")
    methodInput.type = "hidden"
    methodInput.name = "_method"
    methodInput.value = "delete"
    form.appendChild(methodInput)

    document.body.appendChild(form)
    form.requestSubmit()

    this.close()
  }
}
