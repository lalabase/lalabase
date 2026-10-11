// Neo Notification Controller Swipe Tests
// Tests for swipe-to-dismiss functionality

import { Application } from "@hotwired/stimulus"
import NeoNotificationController from "../../../app/javascript/controllers/neo_notification_controller"

describe("NeoNotificationController - Swipe Functionality", () => {
  let application
  let element
  let controller

  beforeEach(() => {
    // Setup Stimulus application
    application = Application.start()
    application.register("neo-notification", NeoNotificationController)

    // Create test element
    element = document.createElement("div")
    element.setAttribute("data-controller", "neo-notification")
    element.setAttribute("data-neo-notification-id-value", "123")
    element.setAttribute("data-neo-notification-archive-url-value", "/notifications/123")
    element.setAttribute("data-neo-notification-mark-read-url-value", "/notifications/123/mark_read")
    element.innerHTML = `
      <div class="notification-content">
        <div class="notification-header">
          <div class="notification-message">Test notification</div>
        </div>
      </div>
    `
    
    document.body.appendChild(element)
    controller = application.getControllerForElementAndIdentifier(element, "neo-notification")
  })

  afterEach(() => {
    document.body.removeChild(element)
    application.stop()
  })

  describe("Swipe Detection", () => {
    it("should initialize swipe functionality on connect", () => {
      expect(controller.touchStartX).toBeDefined()
      expect(controller.touchStartY).toBeDefined()
      expect(controller.isDragging).toBeDefined()
      expect(element.classList.contains('swipeable')).toBe(true)
    })

    it("should detect left swipe and trigger archive", (done) => {
      // Mock fetch for archive request
      global.fetch = jest.fn(() => 
        Promise.resolve({
          ok: true,
          json: () => Promise.resolve({ status: 'archived' })
        })
      )

      // Spy on archive method
      const archiveSpy = jest.spyOn(controller, 'archive')

      // Simulate left swipe
      simulateSwipe(element, -150, 0) // Left swipe 150px

      setTimeout(() => {
        expect(archiveSpy).toHaveBeenCalled()
        done()
      }, 100)
    })

    it("should detect right swipe and trigger mark as read", (done) => {
      // Mock fetch for mark read request
      global.fetch = jest.fn(() => 
        Promise.resolve({
          ok: true,
          json: () => Promise.resolve({ status: 'read' })
        })
      )

      // Spy on markAsRead method
      const markReadSpy = jest.spyOn(controller, 'markAsRead')

      // Simulate right swipe
      simulateSwipe(element, 150, 0) // Right swipe 150px

      setTimeout(() => {
        expect(markReadSpy).toHaveBeenCalled()
        done()
      }, 100)
    })

    it("should not trigger action for small swipe distances", () => {
      const archiveSpy = jest.spyOn(controller, 'archive')
      const markReadSpy = jest.spyOn(controller, 'markAsRead')

      // Simulate small swipe (below threshold)
      simulateSwipe(element, 50, 0)

      expect(archiveSpy).not.toHaveBeenCalled()
      expect(markReadSpy).not.toHaveBeenCalled()
    })

    it("should not trigger swipe for vertical gestures", () => {
      const archiveSpy = jest.spyOn(controller, 'archive')
      
      // Simulate vertical swipe
      simulateSwipe(element, 20, 150) // More vertical than horizontal

      expect(archiveSpy).not.toHaveBeenCalled()
    })
  })

  describe("Visual Feedback", () => {
    it("should add swiping class during swipe", () => {
      const touchStart = createTouchEvent('touchstart', 0, 0)
      element.dispatchEvent(touchStart)

      expect(element.classList.contains('swiping')).toBe(true)
    })

    it("should remove swiping class on swipe end", () => {
      // Start swipe
      const touchStart = createTouchEvent('touchstart', 0, 0)
      element.dispatchEvent(touchStart)
      
      expect(element.classList.contains('swiping')).toBe(true)

      // End swipe
      const touchEnd = createTouchEvent('touchend', 50, 0)
      element.dispatchEvent(touchEnd)

      setTimeout(() => {
        expect(element.classList.contains('swiping')).toBe(false)
      }, 100)
    })

    it("should apply transform during swipe move", () => {
      // Start swipe
      const touchStart = createTouchEvent('touchstart', 0, 0)
      element.dispatchEvent(touchStart)

      // Move during swipe
      const touchMove = createTouchEvent('touchmove', 100, 0)
      element.dispatchEvent(touchMove)

      // Check if transform is applied
      expect(element.style.transform).toContain('translateX')
    })
  })

  describe("Keyboard Shortcuts", () => {
    it("should archive notification on 'a' key press", () => {
      const archiveSpy = jest.spyOn(controller, 'archive')
      
      const keyEvent = new KeyboardEvent('keydown', {
        key: 'a',
        bubbles: true
      })
      
      element.dispatchEvent(keyEvent)
      
      expect(archiveSpy).toHaveBeenCalled()
    })

    it("should mark as read on 'r' key press", () => {
      const markReadSpy = jest.spyOn(controller, 'markAsRead')
      
      const keyEvent = new KeyboardEvent('keydown', {
        key: 'r',
        bubbles: true
      })
      
      element.dispatchEvent(keyEvent)
      
      expect(markReadSpy).toHaveBeenCalled()
    })

    it("should not trigger shortcuts when typing in inputs", () => {
      const archiveSpy = jest.spyOn(controller, 'archive')
      
      // Create input element
      const input = document.createElement('input')
      element.appendChild(input)
      input.focus()
      
      const keyEvent = new KeyboardEvent('keydown', {
        key: 'a',
        target: input,
        bubbles: true
      })
      
      element.dispatchEvent(keyEvent)
      
      expect(archiveSpy).not.toHaveBeenCalled()
    })
  })
})

// Helper functions
function simulateSwipe(element, deltaX, deltaY) {
  const startX = 100
  const startY = 100
  
  // Touch start
  const touchStart = createTouchEvent('touchstart', startX, startY)
  element.dispatchEvent(touchStart)
  
  // Touch move
  const touchMove = createTouchEvent('touchmove', startX + deltaX, startY + deltaY)
  element.dispatchEvent(touchMove)
  
  // Touch end
  const touchEnd = createTouchEvent('touchend', startX + deltaX, startY + deltaY)
  element.dispatchEvent(touchEnd)
}

function createTouchEvent(type, x, y) {
  const touch = {
    clientX: x,
    clientY: y,
    identifier: 0
  }
  
  return new TouchEvent(type, {
    touches: type === 'touchend' ? [] : [touch],
    changedTouches: [touch],
    bubbles: true
  })
}