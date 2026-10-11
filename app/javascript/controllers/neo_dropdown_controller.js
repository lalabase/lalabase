import { Controller } from "@hotwired/stimulus"

// Neo Dropdown Controller
//
// Generic dropdown controller for Neo components.
// Handles opening/closing, click outside detection, keyboard navigation.
//
// Usage:
// <div data-controller="neo-dropdown"
//      data-neo-dropdown-auto-close-value="outside">
//   <button data-neo-dropdown-target="trigger"
//           data-action="click->neo-dropdown#toggle">
//   <div data-neo-dropdown-target="menu">

export default class extends Controller {
  static targets = ["trigger", "menu", "backdrop"]
  static values = { 
    autoClose: String, // "outside", "inside", "disabled", "none"
    placement: String  // "bottom", "top", "left", "right"
  }

  static classes = ["open", "closed"]

  connect() {
    this.isOpen = false
    this.closeOnOutsideClick = this.autoCloseValue === "outside"
    this.closeOnInsideClick = this.autoCloseValue === "inside"

    // Save bound references for cleanup in disconnect()
    this.boundHandleGlobalKeydown = this.handleGlobalKeydown.bind(this)
    this.boundHandleOutsideClick = this.handleOutsideClick.bind(this)
    this.boundHandleInsideClick = this.handleInsideClick.bind(this)
    this.boundHandleViewportChange = () => this.close({ restoreFocus: false })

    // Set initial state
    this.close()

    // Setup keyboard navigation
    document.addEventListener('keydown', this.boundHandleGlobalKeydown)
  }

  disconnect() {
    document.removeEventListener('keydown', this.boundHandleGlobalKeydown)
    this.removeOutsideClickListener()
    this.removeInsideClickListener()
    this.removeViewportListeners()
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    if (this.isOpen) return
    
    this.isOpen = true
    this.menuTarget.style.display = ''
    this.menuTarget.classList.remove('hidden')
    if (this.menuTarget.hasAttribute('popover')) this.menuTarget.showPopover?.()
    
    // Show backdrop if it exists (for mobile)
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.remove('hidden')
    }
    
    // Add classes
    this.element.classList.add('dropdown--open')
    this.triggerTarget.setAttribute('aria-expanded', 'true')
    this.menuTarget.setAttribute('aria-hidden', 'false')
    
    // Position menu (skip for mobile fullscreen)
    if (this.autoCloseValue !== 'none') {
      this.positionMenu()
    }
    if (this.placementValue === 'top-end') {
      window.addEventListener('scroll', this.boundHandleViewportChange, true)
      window.addEventListener('resize', this.boundHandleViewportChange)
    }
    
    // Setup outside click detection
    if (this.closeOnOutsideClick) {
      requestAnimationFrame(() => {
        document.addEventListener('click', this.boundHandleOutsideClick)
      })
    }

    // Setup inside click detection
    if (this.closeOnInsideClick) {
      this.menuTarget.addEventListener('click', this.boundHandleInsideClick)
    }

    // Focus first focusable element
    this.focusFirstElement()
    
    // Dispatch custom event
    this.dispatch('opened', { detail: { dropdown: this } })
  }

  close({ restoreFocus = true } = {}) {
    if (!this.isOpen) return
    
    this.isOpen = false
    if (this.menuTarget.hasAttribute('popover')) this.menuTarget.hidePopover?.()
    this.menuTarget.style.display = 'none'
    this.menuTarget.classList.add('hidden')
    
    // Hide backdrop if it exists (for mobile)
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.add('hidden')
    }
    
    // Remove classes
    this.element.classList.remove('dropdown--open')
    this.triggerTarget.setAttribute('aria-expanded', 'false')  
    this.menuTarget.setAttribute('aria-hidden', 'true')
    
    // Remove event listeners
    this.removeOutsideClickListener()
    this.removeInsideClickListener()
    this.removeViewportListeners()
    
    // Return focus to trigger
    if (restoreFocus) this.triggerTarget.focus()
    
    // Dispatch custom event
    this.dispatch('closed', { detail: { dropdown: this } })
  }

  // Keyboard navigation
  handleGlobalKeydown(event) {
    if (!this.isOpen) return

    switch (event.key) {
      case 'Escape':
        event.preventDefault()
        this.close()
        break
      case 'ArrowDown':
        if (this.menuTarget.contains(document.activeElement)) {
          event.preventDefault()
          this.focusNextElement()
        }
        break
      case 'ArrowUp':
        if (this.menuTarget.contains(document.activeElement)) {
          event.preventDefault()
          this.focusPreviousElement()
        }
        break
      case 'Tab':
        // Handle tab navigation within dropdown
        if (this.menuTarget.contains(document.activeElement)) {
          const focusableElements = this.getFocusableElements()
          const firstElement = focusableElements[0]
          const lastElement = focusableElements[focusableElements.length - 1]
          
          if (event.shiftKey && document.activeElement === firstElement) {
            event.preventDefault()
            lastElement.focus()
          } else if (!event.shiftKey && document.activeElement === lastElement) {
            event.preventDefault()
            firstElement.focus()
          }
        }
        break
    }
  }

  // Click handlers
  handleOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  handleInsideClick(event) {
    // Close on inside click unless it's on a specific element
    if (!event.target.closest('[data-no-close]')) {
      this.close()
    }
  }

  // Focus management
  focusFirstElement() {
    const firstElement = this.getFocusableElements()[0]
    if (firstElement) {
      firstElement.focus()
    }
  }

  focusNextElement() {
    const elements = this.getFocusableElements()
    const currentIndex = elements.indexOf(document.activeElement)
    const nextIndex = (currentIndex + 1) % elements.length
    elements[nextIndex].focus()
  }

  focusPreviousElement() {
    const elements = this.getFocusableElements()
    const currentIndex = elements.indexOf(document.activeElement)
    const prevIndex = currentIndex === 0 ? elements.length - 1 : currentIndex - 1
    elements[prevIndex].focus()
  }

  getFocusableElements() {
    return Array.from(
      this.menuTarget.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )
    ).filter(el => el.offsetParent !== null) // Only visible elements
  }

  // Menu positioning
  positionMenu() {
    // placement "css": the stylesheet owns the position (e.g. an absolute
    // menu inside a relative wrapper). The branches below write VIEWPORT
    // coordinates as inline styles, which is only correct for fixed menus -
    // on an anchored menu they shoved it into the middle of the page
    // (ticket header menu, found live 03.09.).
    if (this.placementValue === 'css') return

    // The reaction picker belongs above the tools corner, in the top layer so
    // a scrolling ticket lane cannot clip it. Its right edge follows the trigger.
    if (this.placementValue === 'top-end') {
      const rect = this.triggerTarget.getBoundingClientRect()
      const menu = this.menuTarget
      menu.style.bottom = 'auto'
      menu.style.right = 'auto'
      menu.style.left = `${Math.max(8, Math.min(rect.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 8))}px`
      menu.style.top = `${Math.max(8, rect.top - menu.offsetHeight - 6)}px`
      return
    }

    const trigger = this.triggerTarget
    const menu = this.menuTarget
    const triggerRect = trigger.getBoundingClientRect()
    const menuRect = menu.getBoundingClientRect()
    const viewportHeight = window.innerHeight
    const viewportWidth = window.innerWidth
    
    // Reset positioning
    menu.style.top = ''
    menu.style.left = ''
    menu.style.right = ''
    menu.style.bottom = ''
    
    // Calculate position based on placement value
    switch (this.placementValue) {
      case 'top':
        menu.style.bottom = `${viewportHeight - triggerRect.top}px`
        break
      case 'left':
        menu.style.right = `${viewportWidth - triggerRect.left}px`
        break
      case 'right':
        menu.style.left = `${triggerRect.right}px`
        break
      default: // 'bottom'
        menu.style.top = `${triggerRect.bottom}px`
        break
    }
    
    // Adjust for viewport boundaries
    this.adjustForViewport()
  }

  adjustForViewport() {
    const menu = this.menuTarget
    const rect = menu.getBoundingClientRect()
    
    // Adjust if menu goes outside viewport
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 10}px`
    }
    if (rect.left < 0) {
      menu.style.left = '10px'
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 10}px`
    }
  }

  // Cleanup helpers
  removeViewportListeners() {
    window.removeEventListener('scroll', this.boundHandleViewportChange, true)
    window.removeEventListener('resize', this.boundHandleViewportChange)
  }

  removeOutsideClickListener() {
    document.removeEventListener('click', this.boundHandleOutsideClick)
  }

  removeInsideClickListener() {
    if (this.hasMenuTarget) {
      this.menuTarget.removeEventListener('click', this.boundHandleInsideClick)
    }
  }
}
