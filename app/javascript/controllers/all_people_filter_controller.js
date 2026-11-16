import { Controller } from "@hotwired/stimulus"

// The tools are redrawn by search responses, so this controller lives on the
// bar around both forms. An organisation visit takes the live search text and
// stops its older request: a late frame response must not restore the old URL.
export default class extends Controller {
  static values = { searchId: String }

  disconnect() {
    this.searchSubmission?.stop()
  }

  rememberSearch(event) {
    const search = document.getElementById(this.searchIdValue)
    if (event.target === search?.form) this.searchSubmission = event.detail.formSubmission
  }

  carrySearch(event) {
    const search = document.getElementById(this.searchIdValue)
    if (search) {
      event.target.elements.namedItem("q").value = search.value
      this.application.getControllerForElementAndIdentifier(search.form, "auto-submit")?.cancelPending()
    }
    this.searchSubmission?.stop()
  }
}
