import { Controller } from "@hotwired/stimulus"

// This controller implements a popover that always appears above all other elements
export default class extends Controller {
  static targets = ["content"]
  
  connect() {
    // Make sure the content target is hidden on load
    if (this.hasContentTarget) {
      this.contentTarget.classList.add("hidden")
    }

    // Position the content in the DOM root
    this.moveContentToRoot()

    // Initialize timers for smoother hover
    this.hideTimer = null
    this.showTimer = null

    // Save bound references for popover hover listeners (bind once, not per show())
    this.boundKeepVisible = this.keepVisible.bind(this)
    this.boundStartHiding = this.startHiding.bind(this)

    // Attach hover listeners once to the popover element
    if (this.popoverElement) {
      this.popoverElement.addEventListener('mouseenter', this.boundKeepVisible)
      this.popoverElement.addEventListener('mouseleave', this.boundStartHiding)
    }
  }

  disconnect() {
    // Remove popover hover listeners
    if (this.popoverElement) {
      this.popoverElement.removeEventListener('mouseenter', this.boundKeepVisible)
      this.popoverElement.removeEventListener('mouseleave', this.boundStartHiding)
    }

    // Clean up when the controller disconnects
    if (this.popoverElement) {
      document.body.removeChild(this.popoverElement)
    }

    // Clean up timers
    if (this.hideTimer) clearTimeout(this.hideTimer)
    if (this.showTimer) clearTimeout(this.showTimer)
  }
  
  // Shows the popover
  show(event) {
    // Clean up timer
    if (this.hideTimer) {
      clearTimeout(this.hideTimer)
      this.hideTimer = null
    }
    
    // Only continue if element and popover exist
    if (!this.element || !this.popoverElement) return
    
    // Start a short show timer for smoother hover
    if (!this.showTimer) {
      this.showTimer = setTimeout(() => {
        this.updatePosition()
        this.popoverElement.classList.remove("hidden")
        this.popoverElement.classList.add("opacity-100")
        this.showTimer = null
      }, 50) // Short delay for smoother behavior
    }
    
    // Popover hover listeners are bound once in connect()
  }
  
  // Keeps the popover visible when the mouse pointer moves into the popover
  keepVisible(event) {
    if (this.hideTimer) {
      clearTimeout(this.hideTimer)
      this.hideTimer = null
    }
  }
  
  // Starts hiding
  startHiding(event) {
    if (!this.hideTimer) {
      this.hideTimer = setTimeout(() => {
        this.hide()
        this.hideTimer = null
      }, 300) // Delay before hiding for smoother behavior
    }
  }
  
  // Hides the popover
  hide(event) {
    // Clean up timer
    if (this.showTimer) {
      clearTimeout(this.showTimer)
      this.showTimer = null
    }
    
    // Only continue if element and popover exist
    if (!this.popoverElement) return
    
    // Start hide timer only if event is present (explicit hide() request without timer runs immediately)
    if (event && !this.hideTimer) {
      this.hideTimer = setTimeout(() => {
        this.popoverElement.classList.add("hidden")
        this.popoverElement.classList.remove("opacity-100")
        this.hideTimer = null
      }, 300) // Delay before hiding
    } else {
      this.popoverElement.classList.add("hidden")
      this.popoverElement.classList.remove("opacity-100")
    }
  }
  
  // Positions the content in the DOM root for maximum z-stacking priority
  moveContentToRoot() {
    if (this.hasContentTarget) {
      // Create a wrapper element
      this.popoverElement = document.createElement("div")
      this.popoverElement.id = `popover-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
      this.popoverElement.classList.add(
        "fixed", "z-popover", "hidden", "opacity-0", "transition-opacity", "duration-200"
      )
      
      // Copy the content into the wrapper
      const contentClone = this.contentTarget.cloneNode(true)
      contentClone.classList.remove("hidden")
      this.popoverElement.appendChild(contentClone)
      
      // Add the wrapper to the body
      document.body.appendChild(this.popoverElement)
      
      // Remove the original content element
      this.contentTarget.remove()
      
      // Position initially
      this.updatePosition()
    }
  }
  
  // Update the popover's position based on the host element
  updatePosition() {
    if (this.popoverElement) {
      const rect = this.element.getBoundingClientRect()
      
      // Position the popover at the top right of the element
      this.popoverElement.style.top = `${rect.top - 10}px`
      this.popoverElement.style.right = `${window.innerWidth - rect.right + 5}px`
    }
  }
}