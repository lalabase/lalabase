import { Controller } from "@hotwired/stimulus"

/**
 * Billing Modal Controller (D4 of doc/abrechnung_detail_angleichung_plan.md)
 *
 * ONE modal shell per page for the two billing forms (edit, billing status).
 * A trigger carries its form's URL as an action param; open() points the
 * shell's turbo-frame at it, so a list renders one shell, not one modal per
 * row. Everything else follows the TimeSession reference pattern
 * (README_MODAL_PATTERN.md).
 */
export default class extends Controller {
  static targets = ["modal", "frame"]
  static values = { loadingText: String }

  connect() {
    this.modalTarget.classList.add("hidden")

    this.handleTurboSuccess = this.handleTurboSuccess.bind(this)
    document.addEventListener("turbo:submit-end", this.handleTurboSuccess)
  }

  disconnect() {
    document.removeEventListener("turbo:submit-end", this.handleTurboSuccess)
  }

  handleTurboSuccess(event) {
    const form = event.target
    const ids = ["billing_edit_form", "billing_status_form"]
    if (form && ids.includes(form.id) && event.detail.success) {
      this.close()
      // The server answers with turbo_stream.refresh, but Turbo discards a
      // refresh whose request-id matches the very submission that caused it
      // (the initiator normally gets a redirect instead). Here the initiator
      // IS the one who must see the new state - head figures, status word,
      // list row - so revisit the current page explicitly (user report,
      // 02.09.: view stayed stale after the status change).
      if (window.Turbo) {
        window.Turbo.visit(window.location.href, { action: "replace" })
      } else {
        window.location.reload()
      }
    }
  }

  open(event) {
    event.preventDefault()
    const url = event.params.url
    if (!url) return

    // Reset first, so reopening the SAME url fetches a clean form.
    this.frameTarget.removeAttribute("src")
    this.frameTarget.innerHTML = this.loadingHtml()
    this.frameTarget.setAttribute("src", url)

    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  // The form's Abbrechen button. In the modal it must CLOSE, not navigate:
  // the link's href points at the billings list, and following it inside the
  // modal frame swaps the form for the list's empty shell frame. On the
  // fallback edit page no billing-modal controller surrounds the form, the
  // action is inert and the href navigates normally.
  cancel(event) {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) {
      event.preventDefault()
      this.close()
    }
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    this.frameTarget.removeAttribute("src")
    this.frameTarget.innerHTML = ""
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

  loadingHtml() {
    const text = this.hasLoadingTextValue ? this.loadingTextValue : "…"
    return '<div class="p-4 text-center text-sm text-cream-600">' + text + "</div>"
  }
}
