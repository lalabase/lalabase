import { Controller } from "@hotwired/stimulus"
import Swipeable from "mixins/swipeable"

// Neo Notification Controller
//
// Handles individual notification item interactions:
// - Click-to-navigate functionality
// - Mark as read actions
// - Swipe-to-dismiss on mobile
// - Keyboard navigation support
//
// Usage:
// <div data-controller="neo-notification"
//      data-neo-notification-url-value="/path/to/item"
//      data-neo-notification-mark-read-url-value="/path/to/mark_read"
//      data-neo-notification-archive-url-value="/path/to/archive"
//      data-action="click->neo-notification#navigate">

export default class extends Controller {
  static values = { 
    url: String,
    markReadUrl: String,
    archiveUrl: String,
    id: String
  }

  static classes = [ 
    "read", 
    "unread", 
    "loading",
    "swiping",
    "dismissing"
  ]

  static targets = [
    // No targets needed - bulk controller handles checkboxes
  ]

  connect() {
    // Initialize swipe functionality
    Object.assign(this, Swipeable)
    this.initializeSwipe()
    
    // Make notification focusable if it has a URL
    if (this.hasUrlValue && this.urlValue) {
      this.element.setAttribute('tabindex', '0')
      this.element.setAttribute('role', 'button')
      this.element.style.cursor = 'pointer'
    }

    // Store notification ID for reference
    if (!this.hasIdValue) {
      this.idValue = this.element.dataset.notificationId || 
                     (this.element.id.startsWith('notification_') ? 
                      this.element.id.substring('notification_'.length) : 
                      this.element.id)
    }
  }

  // Navigate to notification target
  navigate(event) {
    // Prevent navigation if clicking on action buttons
    if (event.target.closest('.notification-actions')) {
      return
    }

    if (this.hasUrlValue && this.urlValue) {
      // Mark as read before navigating (fire and forget)
      this.markAsReadSilently()
      
      // Navigate to target
      if (event.metaKey || event.ctrlKey) {
        // Open in new tab
        window.open(this.urlValue, '_blank')
      } else {
        // Navigate in current window
        window.location.href = this.urlValue
      }
    }
  }

  // Handle keyboard navigation
  keydown(event) {
    // Don't handle keyboard events if user is typing in input/textarea
    if (event.target.matches('input, textarea, select, [contenteditable]')) {
      return
    }

    switch (event.key) {
      case 'Enter':
      case ' ':
        event.preventDefault()
        this.navigate(event)
        break
      case 'r':
        event.preventDefault()
        this.markAsRead()
        break
      case 'a':
        event.preventDefault()
        if (event.shiftKey) {
          // Shift+A = Archive all (delegate to bulk controller)
          this.dispatch('archive-all')
        } else {
          // A = Archive this notification
          this.archive()
        }
        break
      case 'Escape':
        // Escape is handled by bulk controller for selection clearing
        break
    }
  }

  // Mark notification as read with visual feedback
  markAsRead() {
    if (this.hasMarkReadUrlValue && this.markReadUrlValue) {
      this.setLoadingState(true)
      
      fetch(this.markReadUrlValue, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.csrfToken,
          'Accept': 'text/vnd.turbo-stream.html'
        },
        body: JSON.stringify({
          notification: { state: 'read' }
        })
      })
      .then(response => {
        if (response.ok) {
          this.markAsReadLocally()
          // Turbo Stream will handle the server response
        } else {
          this.handleMarkReadError()
        }
      })
      .catch(() => {
        this.handleMarkReadError()
      })
      .finally(() => {
        this.setLoadingState(false)
      })
    }
  }

  // Mark as read without visual feedback (for navigation)
  markAsReadSilently() {
    if (this.hasMarkReadUrlValue && this.markReadUrlValue) {
      navigator.sendBeacon(this.markReadUrlValue, JSON.stringify({
        notification: { state: 'read' }
      }))
      
      // Dispatch custom event for notification manager
      this.dispatch('mark-read', { 
        detail: { 
          notificationId: this.element.dataset.notificationId,
          silent: true 
        } 
      })
    }
  }

  // Visual state management
  markAsReadLocally() {
    this.element.classList.remove('notification-item--unread')
    this.element.classList.add('notification-item--read')
    
    const indicator = this.element.querySelector('.notification-indicator')
    if (indicator) {
      indicator.style.opacity = '0'
      setTimeout(() => {
        indicator.remove()
      }, 200)
    }

    // Update badge counter
    this.updateBadgeCount(-1)
    
    // Dispatch custom event for notification manager
    this.dispatch('mark-read', { 
      detail: { 
        notificationId: this.element.dataset.notificationId,
        silent: false 
      } 
    })
  }

  setLoadingState(loading) {
    if (loading) {
      this.element.classList.add('notification-item--loading')
    } else {
      this.element.classList.remove('notification-item--loading')
    }
  }

  handleMarkReadError() {
    // Visual feedback for error
    this.element.classList.add('notification-item--error')
    setTimeout(() => {
      this.element.classList.remove('notification-item--error')
    }, 2000)
  }

  // Update notification badge count
  updateBadgeCount(delta) {
    const badge = document.querySelector('#notification_badge .notification-badge')
    if (badge) {
      const currentCount = parseInt(badge.textContent.replace('+', '')) || 0
      const newCount = Math.max(0, currentCount + delta)
      
      if (newCount === 0) {
        badge.parentElement.style.display = 'none'
      } else {
        badge.textContent = newCount > 99 ? '99+' : newCount.toString()
        badge.parentElement.style.display = 'block'
      }
    }
  }

  // Archive notification
  archive() {
    if (this.hasArchiveUrlValue && this.archiveUrlValue) {
      this.setLoadingState(true)
      
      fetch(this.archiveUrlValue, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.csrfToken,
          'Accept': 'text/vnd.turbo-stream.html'
        },
        body: JSON.stringify({
          notification: { state: 'archive' }
        })
      })
      .then(response => {
        if (response.ok) {
          this.archiveLocally()
          // Turbo Stream will handle the server response
        } else {
          this.handleArchiveError()
        }
      })
      .catch(() => {
        this.handleArchiveError()
      })
      .finally(() => {
        this.setLoadingState(false)
      })
    }
  }

  // Local visual update for archive
  archiveLocally() {
    this.element.classList.add('notification-item--archived')
    
    // Animate out
    this.element.style.transition = 'opacity 0.3s ease-out, transform 0.3s ease-out'
    this.element.style.opacity = '0'
    this.element.style.transform = 'translateX(-20px)'
    
    // Remove after animation
    setTimeout(() => {
      if (this.element.parentNode) {
        this.element.remove()
      }
    }, 300)
    
    // Update badge counter
    this.updateBadgeCount(-1)
    
    // Dispatch event
    this.dispatch('archived', { 
      detail: { 
        notificationId: this.idValue 
      } 
    })
    
    // Show undo toast
    this.showUndoToast((window.I18n && I18n.t('notifications.item.archived')) || 'Notification archived')
  }

  handleArchiveError() {
    // Visual feedback for error
    this.element.classList.add('notification-item--error')
    setTimeout(() => {
      this.element.classList.remove('notification-item--error')
    }, 2000)
    
    // Reset visual state if swipe caused this
    this.resetSwipeVisual()
  }

  // Selection is handled by bulk controller

  // Swipe handlers (called by Swipeable mixin)
  onSwipeLeft() {
    // Left swipe = Archive
    this.archive()
  }

  onSwipeRight() {
    // Right swipe = Mark as read
    this.markAsRead()
  }

  onSwipeStart() {
    // Add visual feedback class
    this.element.classList.add('swiping')
  }

  onSwipeEnd() {
    // Remove visual feedback class
    this.element.classList.remove('swiping')
  }

  // Show undo toast notification
  showUndoToast(message) {
    // Dispatch event for toast system to handle
    this.dispatch('show-toast', {
      detail: {
        message: message,
        type: 'success',
        action: {
          label: (window.I18n && I18n.t('common.undo')) || 'Undo',
          handler: () => this.undoLastAction()
        },
        duration: 5000
      }
    })
  }

  undoLastAction() {
    // Implementation depends on last action taken
    // For now, just reload the page section
    if (window.Turbo) {
      window.Turbo.visit(window.location.href, { action: 'replace' })
    } else {
      window.location.reload()
    }
  }

  // Disconnect cleanup
  disconnect() {
    if (this.disableSwipe) {
      this.disableSwipe()
    }
  }

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }
}
