import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Prevents navigation to undefined URLs
export default class extends Controller {
  connect() {
    // Monitor all turbo frame src changes
    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        if (mutation.type === 'attributes' && mutation.attributeName === 'src') {
          const frame = mutation.target
          const src = frame.getAttribute('src')
          
          if (src && (src === 'undefined' || src.includes('/undefined'))) {
            console.error('[UNDEFINED URL GUARD] Blocking frame src:', src)
            frame.removeAttribute('src')
            
            // Show error message in frame
            if (frame.id === 'ticket_display_frame') {
              frame.innerHTML = `<div class="p-4 text-center text-red-600">${I18n.t('stimulus.undefined_url_guard.load_error')}</div>`
            }
          }
        }
      })
    })
    
    // Observe all turbo frames
    document.querySelectorAll('turbo-frame').forEach(frame => {
      this.observer.observe(frame, {
        attributes: true,
        attributeFilter: ['src']
      })
    })
    
    // Also prevent navigation via Turbo
    this.boundCheckVisit = this.checkVisit.bind(this)
    this.boundCheckFetch = this.checkFetch.bind(this)
    document.addEventListener('turbo:before-visit', this.boundCheckVisit)
    document.addEventListener('turbo:before-fetch-request', this.boundCheckFetch)
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
    document.removeEventListener('turbo:before-visit', this.boundCheckVisit)
    document.removeEventListener('turbo:before-fetch-request', this.boundCheckFetch)
  }
  
  checkVisit(event) {
    const url = event.detail.url
    if (url && (url === 'undefined' || url.toString().includes('/undefined'))) {
      console.error('[UNDEFINED URL GUARD] Blocking visit to:', url)
      event.preventDefault()
    }
  }
  
  checkFetch(event) {
    const url = event.detail.url
    const urlString = url instanceof URL ? url.toString() : url
    
    if (urlString && (urlString === 'undefined' || urlString.includes('/undefined'))) {
      console.error('[UNDEFINED URL GUARD] Blocking fetch to:', urlString)
      event.preventDefault()
    }
  }
}