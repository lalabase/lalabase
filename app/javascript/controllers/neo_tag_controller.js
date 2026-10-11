import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { 
    removable: Boolean,
    href: String
  }
  
  connect() {
    if (this.hrefValue) {
      this.element.style.cursor = 'pointer'
    }
  }
  
  navigate(event) {
    if (!this.hrefValue) return
    
    // Prevent navigation if clicking the remove button
    if (event.target.closest('.remove-button')) {
      event.stopPropagation()
      return
    }
    
    // Use Turbo for navigation
    if (window.Turbo) {
      event.preventDefault()
      window.Turbo.visit(this.hrefValue)
    } else {
      window.location.href = this.hrefValue
    }
  }
  
  remove(event) {
    event.stopPropagation()
    
    // Dispatch custom event before removing
    const removeEvent = new CustomEvent('neo-tag:before-remove', {
      detail: { tag: this.element },
      bubbles: true,
      cancelable: true
    })
    
    if (this.element.dispatchEvent(removeEvent)) {
      // Animate removal
      this.element.style.transition = 'opacity 200ms, transform 200ms'
      this.element.style.opacity = '0'
      this.element.style.transform = 'scale(0.8)'
      
      setTimeout(() => {
        this.element.remove()
        
        // Dispatch custom event after removing
        document.dispatchEvent(new CustomEvent('neo-tag:removed', {
          detail: { tag: this.element },
          bubbles: true
        }))
      }, 200)
    }
  }
}