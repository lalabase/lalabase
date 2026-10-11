import { Controller } from "@hotwired/stimulus"

// Auto Dismiss Controller
//
// Automatically removes elements after a specified delay
// Useful for toast notifications, flash messages, temporary alerts
//
// Usage:
// <div data-controller="auto-dismiss" 
//      data-auto-dismiss-delay-value="3000">

export default class extends Controller {
  static values = { 
    delay: { type: Number, default: 5000 } // 5 seconds default
  }
  
  connect() {
    this.timer = setTimeout(() => {
      this.dismiss()
    }, this.delayValue)

    // Add hover to pause auto-dismiss
    this.boundPause = this.pause.bind(this)
    this.boundResume = this.resume.bind(this)
    this.element.addEventListener('mouseenter', this.boundPause)
    this.element.addEventListener('mouseleave', this.boundResume)
  }

  disconnect() {
    if (this.timer) {
      clearTimeout(this.timer)
    }
    this.element.removeEventListener('mouseenter', this.boundPause)
    this.element.removeEventListener('mouseleave', this.boundResume)
  }
  
  pause() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }
  
  resume() {
    if (!this.timer) {
      this.timer = setTimeout(() => {
        this.dismiss()
      }, this.delayValue)
    }
  }
  
  dismiss() {
    // Animate out
    this.element.style.transition = 'all 0.3s ease-out'
    this.element.style.opacity = '0'
    this.element.style.transform = 'translateX(100%)'
    
    // Remove after animation
    setTimeout(() => {
      if (this.element.parentNode) {
        this.element.remove()
      }
    }, 300)
  }
}