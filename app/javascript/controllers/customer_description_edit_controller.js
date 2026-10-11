import { Controller } from "@hotwired/stimulus"

// ================================
// CUSTOMER DESCRIPTION EDIT CONTROLLER
// ================================
// Stimulus controller for inline editing of customer descriptions in time sessions.
// Provides edit/save/cancel functionality with character counter and AJAX updates.
//
// Features:
// - Toggle between display and edit modes
// - Real-time character counter (160 max)
// - AJAX save without page reload
// - Visual feedback for success/error states
// - Automatic show/hide of empty states
//
// Usage:
//   <tr data-controller="customer-description-edit"
//       data-customer-description-edit-session-id-value="<session-id>">
//     <td>
//       <div data-customer-description-edit-target="display">...</div>
//       <div data-customer-description-edit-target="editor">
//         <textarea data-customer-description-edit-target="textarea"></textarea>
//         <button data-action="click->customer-description-edit#save">Save</button>
//         <button data-action="click->customer-description-edit#cancel">Cancel</button>
//       </div>
//       <div data-customer-description-edit-target="empty">...</div>
//     </td>
//   </tr>
// ================================

export default class extends Controller {
  static targets = [
    "display",      // Display mode container
    "text",         // Text display element
    "editor",       // Editor mode container
    "textarea",     // Textarea input
    "charCount",    // Character counter display
    "empty",        // Empty state container
    "editButton"    // Edit button
  ]

  static values = {
    sessionId: String,  // Time session ID
    groupId: String     // Time session group ID (from URL)
  }

  connect() {
    // Save bound reference for proper cleanup
    this.boundUpdateCharCount = this.updateCharCount.bind(this)

    // Track timers for cleanup
    this.successTimer = null
    this.errorTimer = null

    // Listen for textarea input to update character count
    if (this.hasTextareaTarget) {
      this.textareaTarget.addEventListener('input', this.boundUpdateCharCount)
    }

    // Get group ID from URL if not provided
    if (!this.hasGroupIdValue) {
      const pathParts = window.location.pathname.split('/')
      const groupIndex = pathParts.indexOf('time_session_groups')
      if (groupIndex !== -1 && pathParts[groupIndex + 1]) {
        this.groupIdValue = pathParts[groupIndex + 1]
      }
    }
  }

  disconnect() {
    if (this.hasTextareaTarget) {
      this.textareaTarget.removeEventListener('input', this.boundUpdateCharCount)
    }

    if (this.successTimer) clearTimeout(this.successTimer)
    if (this.errorTimer) clearTimeout(this.errorTimer)
  }

  // Switch to edit mode
  edit() {
    // Hide display and empty state
    if (this.hasDisplayTarget) {
      this.displayTarget.classList.add('hidden')
    }
    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.add('hidden')
    }

    // Show editor
    this.editorTarget.classList.remove('hidden')

    // Focus textarea
    this.textareaTarget.focus()

    // Update character count
    this.updateCharCount()
  }

  // Save changes via AJAX
  async save() {
    const newDescription = this.textareaTarget.value.trim()

    // Validate length
    if (newDescription.length > 160) {
      this.showError('Beschreibung zu lang (max. 160 Zeichen)')
      return
    }

    // Get CSRF token
    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')

    // Get organisation ID from URL
    const orgId = this.getOrganisationId()

    // Build URL for update endpoint
    const url = `/org/${orgId}/time_session_groups/${this.groupIdValue}/update_customer_description`

    try {
      // Disable save button during request
      const saveButton = this.element.querySelector('[data-action*="save"]')
      saveButton.disabled = true
      saveButton.textContent = 'Speichern...'

      const response = await fetch(url, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': token
        },
        body: JSON.stringify({
          time_session_id: this.sessionIdValue,
          customer_description: newDescription
        })
      })

      const data = await response.json()

      if (data.success) {
        // Update display text
        if (this.hasTextTarget) {
          this.textTarget.textContent = newDescription
        }

        // Switch back to display mode
        this.cancel()

        // Show/hide appropriate states
        if (newDescription.length > 0) {
          if (this.hasDisplayTarget) {
            this.displayTarget.classList.remove('hidden')
          }
          if (this.hasEmptyTarget) {
            this.emptyTarget.classList.add('hidden')
          }
        } else {
          if (this.hasDisplayTarget) {
            this.displayTarget.classList.add('hidden')
          }
          if (this.hasEmptyTarget) {
            this.emptyTarget.classList.remove('hidden')
          }
        }

        // Show success feedback
        this.showSuccess('Gespeichert')
      } else {
        this.showError(data.message || 'Fehler beim Speichern')
      }
    } catch (error) {
      console.error('Error saving customer description:', error)
      this.showError('Netzwerkfehler beim Speichern')
    } finally {
      // Re-enable save button
      const saveButton = this.element.querySelector('[data-action*="save"]')
      saveButton.disabled = false
      saveButton.textContent = 'Speichern'
    }
  }

  // Cancel edit mode
  cancel() {
    // Reset textarea to original value
    if (this.hasTextTarget) {
      this.textareaTarget.value = this.textTarget.textContent.trim()
    }

    // Hide editor
    this.editorTarget.classList.add('hidden')

    // Show display or empty state
    const hasDescription = this.textTarget?.textContent.trim().length > 0

    if (hasDescription && this.hasDisplayTarget) {
      this.displayTarget.classList.remove('hidden')
    } else if (!hasDescription && this.hasEmptyTarget) {
      this.emptyTarget.classList.remove('hidden')
    }

    // Update character count
    this.updateCharCount()
  }

  // Update character counter
  updateCharCount() {
    if (!this.hasCharCountTarget) return

    const length = this.textareaTarget.value.length
    this.charCountTarget.textContent = `${length} / 160 Zeichen`

    // Change color if over limit
    if (length > 160) {
      this.charCountTarget.classList.add('text-red-600')
      this.charCountTarget.classList.remove('text-gray-500')
    } else {
      this.charCountTarget.classList.remove('text-red-600')
      this.charCountTarget.classList.add('text-gray-500')
    }
  }

  // Show success message
  showSuccess(message) {
    // Create temporary success indicator
    const indicator = document.createElement('div')
    indicator.className = 'fixed top-4 right-4 bg-green-500 text-white px-4 py-2 rounded-lg shadow-lg z-toast'
    indicator.textContent = message
    document.body.appendChild(indicator)

    // Remove after 2 seconds
    if (this.successTimer) clearTimeout(this.successTimer)
    this.successTimer = setTimeout(() => {
      indicator.remove()
      this.successTimer = null
    }, 2000)
  }

  // Show error message
  showError(message) {
    // Create temporary error indicator
    const indicator = document.createElement('div')
    indicator.className = 'fixed top-4 right-4 bg-red-500 text-white px-4 py-2 rounded-lg shadow-lg z-toast'
    indicator.textContent = message
    document.body.appendChild(indicator)

    // Remove after 3 seconds
    if (this.errorTimer) clearTimeout(this.errorTimer)
    this.errorTimer = setTimeout(() => {
      indicator.remove()
      this.errorTimer = null
    }, 3000)
  }

  // Get organisation ID from URL
  getOrganisationId() {
    const pathParts = window.location.pathname.split('/')
    const orgIndex = pathParts.indexOf('org')
    if (orgIndex !== -1 && pathParts[orgIndex + 1]) {
      return pathParts[orgIndex + 1]
    }
    return null
  }
}
