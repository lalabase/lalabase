import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  
  connect() {
    this._listenersAttached = false
    this.updateCustomArrow()
  }

  disconnect() {
    const select = this.element.querySelector('select')
    if (select && this._boundHandleFocus) {
      select.removeEventListener('focus', this._boundHandleFocus)
      select.removeEventListener('blur', this._boundHandleBlur)
    }
  }
  
  handleChange(event) {
    const select = event.target
    const selectedValue = select.value
    const selectedText = select.options[select.selectedIndex]?.text
    
    // Update visual state
    this.updateSelectVisuals(select, selectedValue)
    
    // Dispatch custom event for other controllers (e.g., form validation)
    this.dispatch("changed", {
      detail: {
        name: select.name,
        value: selectedValue,
        text: selectedText
      }
    })
  }
  
  updateSelectVisuals(select, value) {
    // Add/remove visual states based on selection
    if (value && value !== '') {
      select.classList.remove('text-gray-400')
      select.classList.add('text-gray-900')
    } else {
      select.classList.remove('text-gray-900')
      select.classList.add('text-gray-400')
    }
    
    // Update custom arrow animation
    this.updateCustomArrow()
  }
  
  updateCustomArrow() {
    const arrow = this.element.querySelector('.pointer-events-none')
    const select = this.element.querySelector('select')

    if (!arrow || !select) return

    // Guard against double-adding listeners
    if (this._listenersAttached) return
    this._listenersAttached = true

    // Animate arrow on focus
    this._boundHandleFocus = () => {
      arrow.style.transform = 'rotate(180deg)'
    }
    this._boundHandleBlur = () => {
      arrow.style.transform = 'rotate(0deg)'
    }

    select.addEventListener('focus', this._boundHandleFocus)
    select.addEventListener('blur', this._boundHandleBlur)
  }
  
  // Public method to enable/disable the select programmatically
  enable() {
    const select = this.element.querySelector('select')
    if (select) {
      select.disabled = false
      select.classList.remove('opacity-50', 'cursor-not-allowed', 'bg-gray-50')
      select.classList.add('cursor-pointer')
    }
  }
  
  disable() {
    const select = this.element.querySelector('select')
    if (select) {
      select.disabled = true
      select.classList.add('opacity-50', 'cursor-not-allowed', 'bg-gray-50')
      select.classList.remove('cursor-pointer')
    }
  }
}