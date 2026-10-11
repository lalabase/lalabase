import { Controller } from "@hotwired/stimulus"

// Neo Notification Bulk Action Controller
//
// Handles bulk actions for notifications like "Mark all as read"
// Provides visual feedback and updates UI state
//
// Usage:
// <button data-controller="neo-notification-bulk-action"
//         data-action="neo-notification-bulk-action#markAllRead">

export default class extends Controller {
  static values = { 
    confirmMessage: String,
    successMessage: String,
    errorMessage: String
  }

  static classes = [
    "loading",
    "success", 
    "error"
  ]

  connect() {
    this.originalText = this.element.innerHTML
  }

  // Mark all notifications as read
  markAllRead(event) {
    event.preventDefault()
    
    // Optional confirmation
    if (this.hasConfirmMessageValue && this.confirmMessageValue) {
      if (!confirm(this.confirmMessageValue)) {
        return
      }
    }

    const url = this.element.href || this.element.dataset.url
    if (!url) {
      console.error('No URL provided for bulk action')
      return
    }

    this.setLoadingState(true)
    
    fetch(url, {
      method: this.element.dataset.method || 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': this.csrfToken,
        'Accept': 'text/vnd.turbo-stream.html'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (response.ok) {
        this.handleSuccess()
        // Turbo Stream will handle the UI updates
        return response.text()
      } else {
        throw new Error(`HTTP ${response.status}`)
      }
    })
    .then(html => {
      // Let Turbo handle the response
      if (html && html.includes('<turbo-stream')) {
        document.body.insertAdjacentHTML('beforeend', html)
      }
    })
    .catch(error => {
      console.error('Bulk action failed:', error)
      this.handleError()
    })
    .finally(() => {
      // Reset state after a delay
      setTimeout(() => {
        this.setLoadingState(false)
      }, 1000)
    })
  }

  // Visual feedback methods
  setLoadingState(loading) {
    if (loading) {
      this.element.disabled = true
      this.element.innerHTML = `
        <span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span>
        ${ (window.I18n && I18n.t('notifications.bulk.processing')) || 'Processing...' }
      `
      this.element.classList.add('btn--loading')
    } else {
      this.element.disabled = false
      this.element.innerHTML = this.originalText
      this.element.classList.remove('btn--loading', 'btn--success', 'btn--error')
    }
  }

  handleSuccess() {
    this.element.innerHTML = `
      <i class="bi bi-check"></i>
      ${this.successMessageValue || (window.I18n && I18n.t('notifications.bulk.done')) || 'Done!'}
    `
    this.element.classList.add('btn--success')
    
    // Update badge count to 0
    this.updateBadgeCount(0)
    
    // Mark all visible notifications as read
    this.markAllVisibleNotificationsAsRead()
    
    // Show success feedback
    this.showToast('success', this.successMessageValue || (window.I18n && I18n.t('notifications.bulk.all_marked')) || 'All notifications marked as read')
    
    // Dispatch custom event for notification manager
    this.dispatch('mark-all-read', { 
      detail: { 
        count: document.querySelectorAll('.notification-item--unread').length
      } 
    })
  }

  handleError() {
    this.element.innerHTML = `
      <i class="bi bi-exclamation-triangle"></i>
      ${this.errorMessageValue || (window.I18n && I18n.t('notifications.bulk.error')) || 'Error'}
    `
    this.element.classList.add('btn--error')
    
    // Show error feedback
    this.showToast('error', this.errorMessageValue || 'Failed to mark notifications as read')
  }

  // Update notification badge
  updateBadgeCount(count) {
    const badges = document.querySelectorAll('.notification-badge')
    badges.forEach(badge => {
      if (count === 0) {
        badge.parentElement.style.display = 'none'
      } else {
        badge.textContent = count > 99 ? '99+' : count.toString()
        badge.parentElement.style.display = 'block'
      }
    })
  }

  // Mark all visible notification items as read
  markAllVisibleNotificationsAsRead() {
    const notificationItems = document.querySelectorAll('.notification-item--unread')
    notificationItems.forEach(item => {
      // Remove unread styling
      item.classList.remove('notification-item--unread')
      item.classList.add('notification-item--read')
      
      // Remove unread indicator
      const indicator = item.querySelector('.notification-indicator')
      if (indicator) {
        indicator.style.opacity = '0'
        setTimeout(() => {
          indicator.remove()
        }, 200)
      }
      
      // Hide action buttons
      const actionButtons = item.querySelectorAll('.notification-actions button')
      actionButtons.forEach(button => {
        button.style.display = 'none'
      })
    })
  }

  // Simple toast notification
  showToast(type, message) {
    // Create toast element
    const toast = document.createElement('div')
    toast.className = `notification-toast notification-toast--${type}`
    toast.innerHTML = `
      <div class="notification-toast-content">
        <i class="bi bi-${type === 'success' ? 'check-circle' : 'exclamation-circle'}"></i>
        <span>${message}</span>
      </div>
    `
    
    // Style the toast
    Object.assign(toast.style, {
      position: 'fixed',
      top: '20px',
      right: '20px',
      zIndex: '9999',
      padding: '12px 16px',
      backgroundColor: type === 'success' ? '#10b981' : '#ef4444',
      color: 'white',
      border: '2px solid #000',
      boxShadow: '4px 4px 0px rgba(0, 0, 0, 1)',
      fontSize: '14px',
      fontWeight: 'bold',
      maxWidth: '300px',
      transform: 'translateX(100%)',
      transition: 'transform 0.3s ease-out'
    })
    
    // Add to DOM
    document.body.appendChild(toast)
    
    // Animate in
    requestAnimationFrame(() => {
      toast.style.transform = 'translateX(0)'
    })
    
    // Remove after delay
    setTimeout(() => {
      toast.style.transform = 'translateX(100%)'
      setTimeout(() => {
        document.body.removeChild(toast)
      }, 300)
    }, 3000)
  }

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }
}

// CSS for toast notifications (if not included in main CSS)
const toastStyles = `
.notification-toast-content {
  display: flex;
  align-items: center;
  gap: 8px;
}

.notification-toast--success {
  background-color: #10b981 !important;
}

.notification-toast--error {
  background-color: #ef4444 !important;
}
`

// Add styles to head if not already present
if (!document.querySelector('#notification-toast-styles')) {
  const style = document.createElement('style')
  style.id = 'notification-toast-styles'
  style.textContent = toastStyles
  document.head.appendChild(style)
}
