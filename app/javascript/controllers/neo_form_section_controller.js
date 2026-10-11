import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "chevron", "header"]
  static values = { 
    expanded: Boolean, 
    collapsible: Boolean 
  }
  
  connect() {
    this.updateVisuals()
  }
  
  toggle() {
    if (!this.collapsibleValue) return
    
    this.expandedValue = !this.expandedValue
    this.updateVisuals()
    
    // Dispatch event for other controllers
    this.dispatch("toggled", {
      detail: {
        sectionId: this.element.id,
        expanded: this.expandedValue
      }
    })
  }
  
  expand() {
    if (!this.collapsibleValue) return
    
    this.expandedValue = true
    this.updateVisuals()
  }
  
  collapse() {
    if (!this.collapsibleValue) return
    
    this.expandedValue = false
    this.updateVisuals()
  }
  
  updateVisuals() {
    // Update content visibility
    if (this.hasContentTarget) {
      if (this.expandedValue) {
        this.contentTarget.classList.remove('hidden')
        this.contentTarget.classList.add('block')
      } else {
        this.contentTarget.classList.remove('block')
        this.contentTarget.classList.add('hidden')
      }
    }
    
    // Update chevron icon
    if (this.hasChevronTarget) {
      if (this.expandedValue) {
        this.chevronTarget.classList.remove('bi-chevron-down')
        this.chevronTarget.classList.add('bi-chevron-up')
        this.chevronTarget.style.transform = 'rotate(0deg)'
      } else {
        this.chevronTarget.classList.remove('bi-chevron-up')  
        this.chevronTarget.classList.add('bi-chevron-down')
        this.chevronTarget.style.transform = 'rotate(0deg)'
      }
    }
    
    // Update section visual state
    this.updateSectionState()
  }
  
  updateSectionState() {
    const section = this.element
    
    if (this.expandedValue) {
      section.classList.remove('shadow-[2px_2px_0_0_#000000]')
      section.classList.add('shadow-[2px_2px_0_0_#000000]')
    } else {
      section.classList.remove('shadow-[2px_2px_0_0_#000000]')
      section.classList.add('shadow-[2px_2px_0_0_#000000]')
    }
  }
  
  // Listen for expand/collapse all events
  expandAll() {
    this.expand()
  }
  
  collapseAll() {
    this.collapse()
  }
}