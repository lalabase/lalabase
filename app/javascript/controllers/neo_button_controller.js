import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["spinner", "content"]
  static values = { 
    loading: Boolean,
    confirm: String
  }
  
  connect() {
    // If button is initially loading, show spinner
    if (this.loadingValue) {
      this.showLoading()
    }

    // Reset loading state after Turbo form submission completes. Turbo fires
    // the submit events on the FORM, so a button inside one listens there.
    this.boundReset = this.hideLoading.bind(this)
    this.boundShow = this.showLoading.bind(this)
    this.form = this.element.tagName === "BUTTON" ? this.element.closest("form") : null
    this.element.addEventListener("turbo:submit-end", this.boundReset)
    if (this.form) this.form.addEventListener("turbo:submit-end", this.boundReset)
  }

  disconnect() {
    this.stopAwaitingLinkSubmission()
    this.element.removeEventListener("turbo:submit-end", this.boundReset)
    if (this.form) {
      this.form.removeEventListener("turbo:submit-end", this.boundReset)
      this.form.removeEventListener("turbo:submit-start", this.boundShow)
    }
  }
  
  async handleClick(event) {
    // Handle confirmation dialog
    if (this.confirmValue && this.confirmValue.length > 0) {
      if (!confirm(this.confirmValue)) {
        event.preventDefault()
        event.stopPropagation()
        return
      }
    }
    
    // For links without data-turbo-method, don't show loading
    // (normal navigation will happen)
    if (this.element.tagName === "A" && !this.element.dataset.turboMethod) {
      return
    }
    
    // A form that asks first (data-turbo-confirm, the form: + confirm: button):
    // Turbo asks after this click. Loading starts only when it really submits;
    // a "no" leaves the button as it was, nothing to restore.
    if (this.form && this.form.dataset.turboConfirm) {
      this.form.removeEventListener("turbo:submit-start", this.boundShow)
      this.form.addEventListener("turbo:submit-start", this.boundShow)
      return
    }

    // A link that writes and asks first (data-turbo-confirm): Turbo makes a form
    // of the click and asks when it submits it. Loading starts only when that
    // form really submits; a "no" leaves the link as it was.
    if (this.element.tagName === "A" && this.element.dataset.turboConfirm) {
      this.awaitLinkSubmission()
      return
    }

    // For forms and turbo-method links, show loading state
    this.showLoading()
  }

  // Turbo's form for a link carries the link's address without its query as the
  // action (the query becomes hidden fields) and is appended to <body>, so its
  // events never pass this element. The listener waits for the next submit of
  // that address; a "no" leaves it for the next click to replace.
  awaitLinkSubmission() {
    this.stopAwaitingLinkSubmission()
    const action = new URL(this.element.href)
    action.search = ""
    this.boundLinkSubmitStart = (event) => {
      const form = event.target
      if (!(form instanceof HTMLFormElement) || form.action !== action.href) return
      this.stopAwaitingLinkSubmission()
      this.showLoading()
      form.addEventListener("turbo:submit-end", this.boundReset, { once: true })
    }
    document.addEventListener("turbo:submit-start", this.boundLinkSubmitStart)
  }

  stopAwaitingLinkSubmission() {
    if (!this.boundLinkSubmitStart) return
    document.removeEventListener("turbo:submit-start", this.boundLinkSubmitStart)
    this.boundLinkSubmitStart = null
  }
  
  showLoading() {
    // Add loading classes
    this.element.classList.add("cursor-wait", "pointer-events-none")
    
    // Show spinner if target exists
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove("hidden")
    }
    
    // Optionally reduce opacity
    if (this.hasContentTarget) {
      this.contentTarget.classList.add("opacity-50")
    }
  }
  
  hideLoading() {
    // Remove loading classes
    this.element.classList.remove("cursor-wait", "pointer-events-none")
    
    // Hide spinner
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add("hidden")
    }
    
    // Restore opacity
    if (this.hasContentTarget) {
      this.contentTarget.classList.remove("opacity-50")
    }
  }
  
  // This can be called from outside to reset the button state
  reset() {
    this.hideLoading()
  }
}