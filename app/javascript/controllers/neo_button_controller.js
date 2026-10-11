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

    // Reset loading state after Turbo form submission completes
    this.boundReset = this.hideLoading.bind(this)
    this.element.addEventListener("turbo:submit-end", this.boundReset)
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.boundReset)
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