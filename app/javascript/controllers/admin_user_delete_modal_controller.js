import { Controller } from "@hotwired/stimulus"

// Confirmation modal for permanently deleting a user in the admin backend.
//
// Replaces a former inline <script> that declared `const requiredEmail` at the top
// level of the document. Turbo Drive re-evaluates body scripts in the SAME realm on
// every navigation, so the second admin user page threw
// "Identifier 'requiredEmail' has already been declared", killing the whole block:
// the input listener was never bound and the delete button stayed disabled forever.
//
// The confirmation here is a UX guard only. The binding check lives server-side in
// Admin::UsersController#destroy and must keep the same comparison rule (trim + downcase).
export default class extends Controller {
  static targets = ["modal", "emailInput", "reasonInput", "submitButton"]
  static values = { email: String }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.emailInputTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    this.emailInputTarget.value = ""
    this.reasonInputTarget.value = ""
    this.submitButtonTarget.disabled = true
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) this.close()
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.modalTarget.classList.contains("hidden")) this.close()
  }

  validate() {
    this.submitButtonTarget.disabled = !this.matches()
  }

  submit(event) {
    if (!this.matches()) event.preventDefault()
  }

  matches() {
    return this.normalize(this.emailInputTarget.value) === this.normalize(this.emailValue)
  }

  normalize(value) {
    return String(value).trim().toLowerCase()
  }
}
