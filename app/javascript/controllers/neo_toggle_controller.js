import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["relatedSelect", "relatedInput", "frequencyContainer"]
  
  connect() {
    this.updateRelatedElements()
  }
  
  toggle(event) {
    const checkbox = event.target
    const isChecked = checkbox.checked
    
    // Update visual state
    this.updateToggleVisuals(checkbox, isChecked)
    
    // Update related form elements
    this.updateRelatedElements()
    
    // Dispatch custom event for other controllers
    this.dispatch("toggled", { 
      detail: { 
        name: checkbox.name,
        checked: isChecked,
        value: isChecked ? "1" : "0"
      }
    })
  }
  
  updateToggleVisuals(checkbox, isChecked) {
    const label = checkbox.closest("label")
    const thumb = label?.querySelector("span")
    
    if (!label || !thumb) return
    
    if (isChecked) {
      // Update track (label) styling with inline styles (more reliable).
      // Must match NeoToggleComponent#track_inline_styles (cobalt-600 = "on", F7).
      label.style.backgroundColor = 'rgb(var(--cobalt-600))'
      label.style.boxShadow = '2px 2px 0 0 #000000'
      
      // Update thumb position based on toggle size with inline styles
      let translateX = '20px' // default medium
      if (label.classList.contains("h-7")) {
        translateX = '24px' // Large toggle
      } else if (label.classList.contains("h-5")) {
        translateX = '16px' // Small toggle
      }
      
      thumb.style.transform = `translateX(${translateX})`
    } else {
      // Reset track (label) styling
      label.style.backgroundColor = '#e5e7eb'
      label.style.boxShadow = 'none'
      
      // Reset thumb position
      thumb.style.transform = 'translateX(2px)'
    }
  }
  
  updateRelatedElements() {
    const isChecked = this.element.querySelector("input[type='checkbox']")?.checked || false
    
    // Enable/disable related select dropdowns based on toggle state
    this.relatedSelectTargets.forEach(select => {
      select.disabled = !isChecked
      
      if (!isChecked) {
        select.classList.add("opacity-50", "cursor-not-allowed")
      } else {
        select.classList.remove("opacity-50", "cursor-not-allowed")
      }
    })
    
    // Enable/disable related inputs
    this.relatedInputTargets.forEach(input => {
      input.disabled = !isChecked
      
      if (!isChecked) {
        input.classList.add("opacity-50", "cursor-not-allowed")
      } else {
        input.classList.remove("opacity-50", "cursor-not-allowed")
      }
    })
    
    // Show/hide frequency containers (for email notifications)
    this.frequencyContainerTargets.forEach(container => {
      if (isChecked) {
        container.classList.remove("hidden")
      } else {
        container.classList.add("hidden")
      }
    })
  }
  
  isRelatedToggleChecked(element) {
    // Find the related toggle by parsing the name pattern
    const toggleName = this.element.querySelector("input[type='checkbox']")?.name
    return this.element.querySelector("input[type='checkbox']")?.checked || false
  }
}