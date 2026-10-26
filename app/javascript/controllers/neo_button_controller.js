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

    // For forms and turbo-method links, show loading state
    this.showLoading()
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