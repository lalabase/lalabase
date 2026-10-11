import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["viewModeInput"]
  
  connect() {
    this.searchTimeout = null
  }
  
  disconnect() {
    if (this.searchTimeout) {
      clearTimeout(this.searchTimeout)
    }
  }
  
  debounceSearch(event) {
    if (this.searchTimeout) {
      clearTimeout(this.searchTimeout)
    }
    
    this.searchTimeout = setTimeout(() => {
      this.submitForm()
    }, 300)
  }
  
  toggleViewMode(event) {
    const viewMode = event.target.dataset.viewMode
    this.viewModeInputTarget.value = viewMode
    
    // Update button states
    this.element.querySelectorAll('[data-view-mode]').forEach(button => {
      if (button.dataset.viewMode === viewMode) {
        button.classList.remove('bg-white', 'hover:bg-gray-50')
        button.classList.add('bg-lime-200')
      } else {
        button.classList.remove('bg-lime-200')
        button.classList.add('bg-white', 'hover:bg-gray-50')
      }
    })
    
    this.submitForm()
  }
  
  submitForm() {
    // The controller is mounted ON the <form>, so the form is this.element.
    // (Stay robust if it is ever moved onto a wrapper: fall back to a
    // descendant form.) Looking only for a descendant returned null here,
    // so the change/input never submitted and the filter did nothing.
    const form = this.element.matches('form')
      ? this.element
      : this.element.querySelector('form')
    if (form) {
      // Defer one frame so the changed value is committed before submit.
      requestAnimationFrame(() => {
        form.requestSubmit()
      })
    }
  }
}