import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]
  
  connect() {
    // Close dropdown when clicking outside
    this.closeOnClickOutside = this.closeOnClickOutside.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
  }
  
  toggle(event) {
    event.stopPropagation()
    
    if (this.hasMenuTarget) {
      const isOpen = !this.menuTarget.classList.contains("hidden")
      
      // Close all other dropdowns first
      document.querySelectorAll('[data-controller="dropdown"] [data-dropdown-target="menu"]').forEach(menu => {
        if (menu !== this.menuTarget) {
          menu.classList.add("hidden")
        }
      })
      
      if (isOpen) {
        this.close()
      } else {
        this.open()
      }
    }
  }
  
  open() {
    if (this.hasMenuTarget) {
      this.menuTarget.classList.remove("hidden")
      
      // Ensure dropdown doesn't go off-screen
      this.adjustPosition()
      
      // Add active state to button
      if (this.hasButtonTarget) {
        this.buttonTarget.classList.add("text-gray-900", "border-indigo-500")
        this.buttonTarget.classList.remove("text-gray-500", "border-transparent")
      }
      
      // Add event listeners
      document.addEventListener("click", this.closeOnClickOutside)
      document.addEventListener("keydown", this.closeOnEscape)
    }
  }
  
  adjustPosition() {
    if (!this.hasMenuTarget) return
    
    const menu = this.menuTarget
    const rect = menu.getBoundingClientRect()
    const viewportHeight = window.innerHeight
    
    // Reset any previous adjustments
    menu.style.transform = ""
    
    // Check if dropdown goes below viewport
    if (rect.bottom > viewportHeight) {
      // Position dropdown above the trigger instead. The button target is
      // optional (Neo::OverflowMenuComponent renders none, and reading it
      // unguarded threw here, which left a menu near the bottom of the
      // viewport clipped AND without its dismissal handlers); the controller
      // element wraps the trigger, so its height is the trigger's.
      const triggerHeight = this.hasButtonTarget ? this.buttonTarget.offsetHeight : this.element.offsetHeight
      menu.style.transform = `translateY(calc(-100% - ${triggerHeight}px - 8px))`
    }
  }
  
  close() {
    if (this.hasMenuTarget) {
      this.menuTarget.classList.add("hidden")
      
      // Remove active state from button
      if (this.hasButtonTarget) {
        this.buttonTarget.classList.remove("text-gray-900", "border-indigo-500")
        this.buttonTarget.classList.add("text-gray-500", "border-transparent")
      }
      
      // Remove event listeners
      document.removeEventListener("click", this.closeOnClickOutside)
      document.removeEventListener("keydown", this.closeOnEscape)
    }
  }
  
  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }
  
  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasMenuTarget && !this.menuTarget.classList.contains("hidden")
  }

  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }
  
  disconnect() {
    // Clean up event listeners
    document.removeEventListener("click", this.closeOnClickOutside)
    document.removeEventListener("keydown", this.closeOnEscape)
  }
}