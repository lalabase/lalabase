import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"
import { openEditModal, performDelete } from "time_session_modal"

// TimeSession Popup Controller
// Manages hover popup for TimeSession icons and delegates edit/delete to shared module
export default class extends Controller {
  static targets = ["icon"]

  connect() {
    this.ensurePopupContainerExists()
  }

  disconnect() {
    this.modalCleanup?.()
    // Clean up popup container listeners created by this instance
    const container = document.getElementById('time-session-popup-container')
    if (container && this._boundPopupMouseover) {
      container.removeEventListener('mouseover', this._boundPopupMouseover)
      container.removeEventListener('mouseout', this._boundPopupMouseout)
    }
  }

  // Create the popup container if it does not yet exist
  ensurePopupContainerExists() {
    if (document.getElementById('time-session-popup-container')) return

    const popup = document.createElement('div')
    popup.id = 'time-session-popup-container'
    popup.style.cssText = 'position:fixed;z-index:70;display:none;background:white;border:2px solid black;border-radius:0.5rem;box-shadow:4px 4px 0 0 #000;padding:0.5rem 0.75rem;min-width:250px;max-width:300px'

    // Prevent the popup from disappearing when the mouse moves over it
    this._boundPopupMouseover = function() {
      this.style.display = 'block'
    }
    popup.addEventListener('mouseover', this._boundPopupMouseover)

    // Delayed hiding when leaving the popup
    this._boundPopupMouseout = function() {
      setTimeout(() => {
        if (this.querySelector(':hover') === null) {
          this.style.display = 'none'
          this.dataset.activeId = ''
        }
      }, 100)
    }
    popup.addEventListener('mouseout', this._boundPopupMouseout)

    document.body.appendChild(popup)
  }

  // Show popup on hover over the icon
  showPopup(event) {
    const container = document.getElementById('time-session-popup-container')
    if (!container) {
      this.ensurePopupContainerExists()
      return
    }

    const icon = event.currentTarget
    const rect = icon.getBoundingClientRect()
    const timeSessionId = icon.dataset.timeSessionId

    // Position of the popup relative to the icon
    container.style.top = (rect.top - 10) + 'px'
    container.style.left = rect.right + 'px'

    // Adjust if the popup extends beyond the viewport on the right
    if (rect.right + 300 > window.innerWidth) {
      container.style.left = (rect.left - 300) + 'px'
    }

    // Adjust if the popup extends beyond the viewport at the bottom
    const containerRect = container.getBoundingClientRect()
    if (rect.top - 10 + containerRect.height > window.innerHeight) {
      container.style.top = (window.innerHeight - containerRect.height - 10) + 'px'
    }

    // Only update the content if the active TimeSession has changed
    if (container.dataset.activeId !== timeSessionId) {
      container.dataset.activeId = timeSessionId

      const { duration, creator, date, description, creatorId, currentUserId } = icon.dataset

      let content = `
        <div class="flex justify-between items-start">
          <span class="text-sm font-medium text-gray-700 mr-2">${duration}</span>`

      if (creatorId === currentUserId) {
        content += `
          <div class="flex space-x-2">
            <button type="button"
                    class="flex-shrink-0 flex items-center justify-center w-6 h-6 rounded-full bg-white hover:bg-gray-100 border border-gray-200"
                    data-action="click->time-session-popup#editTimeSession"
                    data-time-session-id="${timeSessionId}">
              <i class="bi bi-pencil text-gray-500 text-xs"></i>
            </button>
            <button type="button"
                    class="flex-shrink-0 flex items-center justify-center w-6 h-6 rounded-full bg-white hover:bg-gray-100 border border-gray-200"
                    data-action="click->time-session-popup#deleteTimeSession"
                    data-time-session-id="${timeSessionId}">
              <i class="bi bi-trash text-red-500 text-xs"></i>
            </button>
          </div>`
      }

      content += `
        </div>
        <p class="text-xs text-gray-500 mt-1">
          ${creator} | ${date}`

      if (description) {
        content += `<br><span class="italic">${description}</span>`
      }

      content += `</p>`
      container.innerHTML = content

      // Bind action handlers for dynamically created buttons
      // Save bound refs so they can be cleaned up when content changes
      this._boundEditTimeSession = this.editTimeSession.bind(this)
      this._boundDeleteTimeSession = this.deleteTimeSession.bind(this)
      container.querySelectorAll('[data-action*="editTimeSession"]').forEach(btn => {
        btn.addEventListener('click', this._boundEditTimeSession)
      })
      container.querySelectorAll('[data-action*="deleteTimeSession"]').forEach(btn => {
        btn.addEventListener('click', this._boundDeleteTimeSession)
      })
    }

    container.style.display = 'block'
  }

  // Hide Popup
  hidePopup() {
    const container = document.getElementById('time-session-popup-container')
    if (container) {
      setTimeout(() => {
        if (container.querySelector(':hover') === null) {
          container.style.display = 'none'
        }
      }, 100)
    }
  }

  // Edit a TimeSession — delegates to shared module
  editTimeSession(event) {
    event.preventDefault()
    event.stopPropagation()

    const timeSessionId = event.currentTarget.dataset.timeSessionId
    const projectId = this.element.dataset.projectId

    // Determine context and ticketId from various sources
    let ticketId, context
    if (event.currentTarget.hasAttribute('data-context')) {
      context = event.currentTarget.dataset.context
      ticketId = event.currentTarget.dataset.ticketId
    } else {
      const iconElement = document.querySelector(`[data-time-session-id="${timeSessionId}"]`)
      ticketId = iconElement?.closest('[data-ticket-id]')?.dataset.ticketId
      context = this.element.dataset.context || 'ticket'
    }

    // Close the popup
    const container = document.getElementById('time-session-popup-container')
    if (container) container.style.display = 'none'

    const { cleanup } = openEditModal({ projectId, timeSessionId, ticketId, context })
    this.modalCleanup = cleanup
  }

  // Delete a TimeSession — delegates to shared module
  deleteTimeSession(event) {
    event.preventDefault()
    event.stopPropagation()

    const timeSessionId = event.currentTarget.dataset.timeSessionId
    if (!I18n.confirm('stimulus.time_session.confirm_delete')) return

    const projectId = this.element.dataset.projectId

    // Loading indicator in the popup
    const popup = document.getElementById('time-session-popup-container')
    if (popup) {
      popup.innerHTML = `
        <div class="text-center py-2">
          <i class="bi bi-arrow-repeat animate-spin inline-block"></i>
          <p class="text-xs mt-1">${I18n.t('stimulus.time_session_actions.deleting')}</p>
        </div>
      `
    }

    performDelete(projectId, timeSessionId).catch(() => {
      if (popup) {
        popup.innerHTML = `
          <div class="text-center py-2 text-red-500">
            <i class="bi bi-exclamation-triangle"></i>
            <p class="text-xs mt-1">${I18n.t('stimulus.time_session_actions.delete_error')}</p>
          </div>
        `
        setTimeout(() => { popup.style.display = 'none' }, 2000)
      }
    })
  }
}
