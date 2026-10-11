import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Handles errors in Turbo Frames to prevent full page navigation on 404s
export default class extends Controller {
  connect() {
    // Save bound references for proper cleanup
    this.boundHandleMissing = this.handleMissing.bind(this)
    this.boundHandleError = this.handleError.bind(this)
    this.boundHandleRender = this.handleRender.bind(this)

    // Listen for frame fetch errors
    this.element.addEventListener('turbo:frame-missing', this.boundHandleMissing)
    this.element.addEventListener('turbo:fetch-request-error', this.boundHandleError)
    this.element.addEventListener('turbo:frame-render', this.boundHandleRender)
  }

  disconnect() {
    this.element.removeEventListener('turbo:frame-missing', this.boundHandleMissing)
    this.element.removeEventListener('turbo:fetch-request-error', this.boundHandleError)
    this.element.removeEventListener('turbo:frame-render', this.boundHandleRender)
  }
  
  handleMissing(event) {
    console.error('[FRAME ERROR] Frame missing:', event.detail)
    event.preventDefault()
    
    // Show error message in frame instead of navigating
    this.showError(I18n.t('stimulus.frame_error.content_not_found'))
  }
  
  handleError(event) {
    console.error('[FRAME ERROR] Fetch error:', event.detail)
    
    // Check if the URL contains 'undefined'
    const url = event.detail.fetchOptions?.url || event.detail.url || ''
    if (url.includes('undefined')) {
      console.error('[FRAME ERROR] URL contains undefined:', url)
      event.preventDefault()
      event.stopPropagation()
      this.showError(I18n.t('stimulus.frame_error.invalid_url'))
      return
    }
    
    // For 404 errors, prevent full page navigation
    if (event.detail.fetchResponse?.response?.status === 404) {
      event.preventDefault()
      this.showError(I18n.t('stimulus.frame_error.page_not_found'))
    }
  }
  
  handleRender(event) {
    // Clear any error messages when successfully rendering
    const errorDiv = this.element.querySelector('.frame-error-message')
    if (errorDiv) {
      errorDiv.remove()
    }
  }
  
  showError(message) {
    // Remove existing error if any
    const existingError = this.element.querySelector('.frame-error-message')
    if (existingError) {
      existingError.remove()
    }
    
    // Show error message
    const errorDiv = document.createElement('div')
    errorDiv.className = 'frame-error-message p-4 text-center text-red-600 bg-red-50 border border-red-200 rounded m-4'
    errorDiv.innerHTML = `
      <p class="font-medium">${message}</p>
      <button class="mt-2 text-sm underline hover:no-underline" onclick="window.location.reload()">
        ${I18n.t('stimulus.frame_error.reload_page')}
      </button>
    `
    
    this.element.prepend(errorDiv)
  }
}