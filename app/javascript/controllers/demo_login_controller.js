import { Controller } from "@hotwired/stimulus"

// Demo mode: puts the published login into the sign-in form around it
// (devise/sessions/_demo_login). The values come from the server; nothing is
// submitted here, the visitor still presses "Sign in".
export default class extends Controller {
  static values = { email: String, password: String }

  fill() {
    const form = this.element.closest("form")
    form.elements["user[email]"].value = this.emailValue
    form.elements["user[password]"].value = this.passwordValue
    form.querySelector('[type="submit"]').focus()
  }
}
