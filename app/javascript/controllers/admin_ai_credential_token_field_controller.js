import { Controller } from "@hotwired/stimulus"

// Swaps the credential secret input between the single-line API-key field and
// the multi-line service-account JSON textarea (google), driven by the
// provider select. Both fields post ai_credential[access_token]; only one is
// enabled at a time so exactly one value is submitted. Initial visibility is
// rendered server-side from the record's provider — connect() just re-syncs
// (e.g. after a validation re-render or a preset changing the provider).
const GOOGLE_PROVIDER = "google"

export default class extends Controller {
  static targets = ["apiKey", "saJson", "provider"]

  connect() {
    this.toggle()
  }

  toggle() {
    const google = this.providerTarget.value === GOOGLE_PROVIDER
    this.#switch(this.apiKeyTarget, !google)
    this.#switch(this.saJsonTarget, google)
  }

  #switch(wrapper, enabled) {
    wrapper.hidden = !enabled
    const input = wrapper.querySelector("input, textarea")
    if (input) input.disabled = !enabled
  }
}
