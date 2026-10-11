import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Controller for the registration toggle in the admin area
export default class extends Controller {
  static targets = ["checkbox", "form", "button", "statusText"]
  
  connect() {
    // Registration toggle controller connected
  }
  
  // Toggle the checkbox state when the button is clicked
  toggle(event) {
    event.preventDefault()
    
    // Toggle checkbox
    const checkbox = this.checkboxTarget
    checkbox.checked = !checkbox.checked
    
    // Update button text based on new state
    this.updateButtonText(checkbox.checked)
    
    // Update status text
    this.updateStatusText(checkbox.checked)
  }
  
  // Update button text based on checkbox state
  updateButtonText(isChecked) {
    if (this.hasButtonTarget) {
      const button = this.buttonTarget
      const icon = button.querySelector('i')
      const titleText = button.querySelector('span.block.font-bold')
      const subText = button.querySelector('span.block.text-sm')
      
      if (isChecked) {
        icon.className = 'bi bi-unlock text-xl mr-3'
        titleText.textContent = 'Registrierungen deaktivieren'
        subText.textContent = 'Klicken zum Sperren'
        button.classList.remove('bg-red-100', 'hover:bg-red-200')
        button.classList.add('bg-lime-200', 'hover:bg-lime-300')
      } else {
        icon.className = 'bi bi-lock text-xl mr-3'
        titleText.textContent = 'Registrierungen aktivieren'
        subText.textContent = 'Klicken zum Freischalten'
        button.classList.remove('bg-lime-200', 'hover:bg-lime-300')
        button.classList.add('bg-red-100', 'hover:bg-red-200')
      }
    }
  }
  
  // Update status text
  updateStatusText(isChecked) {
    if (this.hasStatusTextTarget) {
      const statusText = this.statusTextTarget
      statusText.textContent = isChecked ? 
        I18n.t('stimulus.registration_toggle.enabled') :
        I18n.t('stimulus.registration_toggle.disabled')
    }
  }
  
  // Checkbox was changed directly
  checkboxChanged(event) {
    this.updateButtonText(event.target.checked)
    this.updateStatusText(event.target.checked)
  }
}