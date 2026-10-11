import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "button"]

  connect() {
    this.contentTarget.classList.add('hidden')
    this.buttonTarget.classList.remove('hidden')
  }

  toggle() {
    this.contentTarget.classList.toggle('hidden')
    this.buttonTarget.classList.toggle('hidden')
  }

  hide() {
    this.contentTarget.classList.add('hidden')
    this.buttonTarget.classList.remove('hidden')
  }

  show() {
    this.contentTarget.classList.remove('hidden')
    this.buttonTarget.classList.add('hidden')
  }
}