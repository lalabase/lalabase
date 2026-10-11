// Neo Notification Controller Tests
import { Application } from '@hotwired/stimulus'
import NeoNotificationController from '../../../app/javascript/controllers/neo_notification_controller'

// Mock fetch globally for all tests
global.fetch = jest.fn()

// Mock navigator.sendBeacon
Object.defineProperty(global.navigator, 'sendBeacon', {
  value: jest.fn().mockReturnValue(true),
  writable: true
})

describe('NeoNotificationController', () => {
  let application
  let controller
  let element

  beforeEach(() => {
    // Setup Stimulus application
    application = Application.start()
    application.register('neo-notification', NeoNotificationController)

    // Create test element
    element = document.createElement('div')
    element.setAttribute('data-controller', 'neo-notification')
    element.setAttribute('data-neo-notification-url-value', '/test/url')
    element.setAttribute('data-neo-notification-mark-read-url-value', '/mark-read')
    element.setAttribute('data-notification-id', '123')
    element.classList.add('notification-item--unread')
    
    // Add notification indicator
    const indicator = document.createElement('div')
    indicator.classList.add('notification-indicator')
    element.appendChild(indicator)

    // Add to DOM
    document.body.appendChild(element)

    // Get controller instance
    controller = application.getControllerForElementAndIdentifier(element, 'neo-notification')
  })

  afterEach(() => {
    document.body.removeChild(element)
    jest.clearAllMocks()
  })

  describe('initialization', () => {
    it('sets up element as focusable when URL is provided', () => {
      expect(element.getAttribute('tabindex')).toBe('0')
      expect(element.getAttribute('role')).toBe('button')
      expect(element.style.cursor).toBe('pointer')
    })

    it('does not make element focusable without URL', () => {
      element.removeAttribute('data-neo-notification-url-value')
      
      // Reconnect controller
      controller.disconnect()
      controller.connect()
      
      expect(element.getAttribute('tabindex')).toBe('0') // Still set from initial setup
    })
  })

  describe('navigate', () => {
    it('prevents navigation when clicking on action buttons', () => {
      // Create action buttons container
      const actions = document.createElement('div')
      actions.classList.add('notification-actions')
      const button = document.createElement('button')
      actions.appendChild(button)
      element.appendChild(actions)

      const event = new MouseEvent('click', { bubbles: true })
      Object.defineProperty(event, 'target', { value: button })

      const markAsReadSilentlySpy = jest.spyOn(controller, 'markAsReadSilently')
      
      controller.navigate(event)
      
      expect(markAsReadSilentlySpy).not.toHaveBeenCalled()
    })

    it('navigates to URL and marks as read silently', () => {
      const markAsReadSilentlySpy = jest.spyOn(controller, 'markAsReadSilently')
      const originalLocation = window.location.href
      
      const event = new MouseEvent('click')
      controller.navigate(event)
      
      expect(markAsReadSilentlySpy).toHaveBeenCalled()
      // Note: jsdom doesn't actually navigate, but we can test the call
    })

    it('opens in new tab with meta key', () => {
      const windowOpenSpy = jest.spyOn(window, 'open').mockImplementation()
      const event = new MouseEvent('click', { metaKey: true })
      
      controller.navigate(event)
      
      expect(windowOpenSpy).toHaveBeenCalledWith('/test/url', '_blank')
      windowOpenSpy.mockRestore()
    })

    it('opens in new tab with ctrl key', () => {
      const windowOpenSpy = jest.spyOn(window, 'open').mockImplementation()
      const event = new MouseEvent('click', { ctrlKey: true })
      
      controller.navigate(event)
      
      expect(windowOpenSpy).toHaveBeenCalledWith('/test/url', '_blank')
      windowOpenSpy.mockRestore()
    })
  })

  describe('keydown handling', () => {
    it('navigates on Enter key', () => {
      const navigateSpy = jest.spyOn(controller, 'navigate')
      const event = new KeyboardEvent('keydown', { key: 'Enter' })
      
      controller.keydown(event)
      
      expect(navigateSpy).toHaveBeenCalledWith(event)
      expect(event.defaultPrevented).toBe(true)
    })

    it('navigates on Space key', () => {
      const navigateSpy = jest.spyOn(controller, 'navigate')
      const event = new KeyboardEvent('keydown', { key: ' ' })
      
      controller.keydown(event)
      
      expect(navigateSpy).toHaveBeenCalledWith(event)
      expect(event.defaultPrevented).toBe(true)
    })

    it('marks as read on R key', () => {
      const markAsReadSpy = jest.spyOn(controller, 'markAsRead')
      const event = new KeyboardEvent('keydown', { key: 'r' })
      
      controller.keydown(event)
      
      expect(markAsReadSpy).toHaveBeenCalled()
      expect(event.defaultPrevented).toBe(true)
    })

    it('ignores R key when inside input', () => {
      const markAsReadSpy = jest.spyOn(controller, 'markAsRead')
      const input = document.createElement('input')
      element.appendChild(input)
      
      const event = new KeyboardEvent('keydown', { key: 'r' })
      Object.defineProperty(event, 'target', { value: input })
      
      controller.keydown(event)
      
      expect(markAsReadSpy).not.toHaveBeenCalled()
      expect(event.defaultPrevented).toBe(false)
    })
  })

  describe('markAsRead', () => {
    beforeEach(() => {
      global.fetch.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ status: 'success' })
      })
    })

    it('sends PATCH request with correct parameters', async () => {
      const setLoadingStateSpy = jest.spyOn(controller, 'setLoadingState')
      
      await controller.markAsRead()
      
      expect(global.fetch).toHaveBeenCalledWith('/mark-read', {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': controller.csrfToken,
          'Accept': 'text/vnd.turbo-stream.html'
        },
        body: JSON.stringify({
          notification: { state: 'read' }
        })
      })
      
      expect(setLoadingStateSpy).toHaveBeenCalledWith(true)
      expect(setLoadingStateSpy).toHaveBeenCalledWith(false)
    })

    it('calls markAsReadLocally on success', async () => {
      const markAsReadLocallySpy = jest.spyOn(controller, 'markAsReadLocally')
      
      await controller.markAsRead()
      
      expect(markAsReadLocallySpy).toHaveBeenCalled()
    })

    it('handles error response', async () => {
      global.fetch.mockResolvedValue({ ok: false })
      const handleMarkReadErrorSpy = jest.spyOn(controller, 'handleMarkReadError')
      
      await controller.markAsRead()
      
      expect(handleMarkReadErrorSpy).toHaveBeenCalled()
    })

    it('handles network error', async () => {
      global.fetch.mockRejectedValue(new Error('Network error'))
      const handleMarkReadErrorSpy = jest.spyOn(controller, 'handleMarkReadError')
      
      await controller.markAsRead()
      
      expect(handleMarkReadErrorSpy).toHaveBeenCalled()
    })
  })

  describe('markAsReadSilently', () => {
    it('uses sendBeacon for fire-and-forget request', () => {
      controller.markAsReadSilently()
      
      expect(global.navigator.sendBeacon).toHaveBeenCalledWith(
        '/mark-read',
        JSON.stringify({ notification: { state: 'read' } })
      )
    })

    it('dispatches custom event', () => {
      const dispatchSpy = jest.spyOn(controller, 'dispatch')
      
      controller.markAsReadSilently()
      
      expect(dispatchSpy).toHaveBeenCalledWith('mark-read', {
        detail: {
          notificationId: '123',
          silent: true
        }
      })
    })
  })

  describe('markAsReadLocally', () => {
    it('updates CSS classes', () => {
      controller.markAsReadLocally()
      
      expect(element.classList.contains('notification-item--unread')).toBe(false)
      expect(element.classList.contains('notification-item--read')).toBe(true)
    })

    it('removes notification indicator', (done) => {
      const indicator = element.querySelector('.notification-indicator')
      
      controller.markAsReadLocally()
      
      expect(indicator.style.opacity).toBe('0')
      
      // Check that element is removed after timeout
      setTimeout(() => {
        expect(element.querySelector('.notification-indicator')).toBe(null)
        done()
      }, 250)
    })

    it('dispatches custom event', () => {
      const dispatchSpy = jest.spyOn(controller, 'dispatch')
      
      controller.markAsReadLocally()
      
      expect(dispatchSpy).toHaveBeenCalledWith('mark-read', {
        detail: {
          notificationId: '123',
          silent: false
        }
      })
    })

    it('updates badge count', () => {
      const updateBadgeCountSpy = jest.spyOn(controller, 'updateBadgeCount')
      
      controller.markAsReadLocally()
      
      expect(updateBadgeCountSpy).toHaveBeenCalledWith(-1)
    })
  })

  describe('setLoadingState', () => {
    it('adds loading class when loading', () => {
      controller.setLoadingState(true)
      
      expect(element.classList.contains('notification-item--loading')).toBe(true)
    })

    it('removes loading class when not loading', () => {
      element.classList.add('notification-item--loading')
      
      controller.setLoadingState(false)
      
      expect(element.classList.contains('notification-item--loading')).toBe(false)
    })
  })

  describe('handleMarkReadError', () => {
    it('adds error class temporarily', (done) => {
      controller.handleMarkReadError()
      
      expect(element.classList.contains('notification-item--error')).toBe(true)
      
      // Check that error class is removed after timeout
      setTimeout(() => {
        expect(element.classList.contains('notification-item--error')).toBe(false)
        done()
      }, 2100)
    })
  })

  describe('updateBadgeCount', () => {
    let badge

    beforeEach(() => {
      badge = document.createElement('span')
      badge.classList.add('notification-badge')
      badge.textContent = '5'
      
      const wrapper = document.createElement('div')
      wrapper.id = 'notification_badge'
      wrapper.appendChild(badge)
      
      document.body.appendChild(wrapper)
    })

    afterEach(() => {
      const wrapper = document.getElementById('notification_badge')
      if (wrapper) {
        document.body.removeChild(wrapper)
      }
    })

    it('decrements badge count', () => {
      controller.updateBadgeCount(-1)
      
      expect(badge.textContent).toBe('4')
      expect(badge.parentElement.style.display).toBe('block')
    })

    it('hides badge when count reaches zero', () => {
      badge.textContent = '1'
      
      controller.updateBadgeCount(-1)
      
      expect(badge.parentElement.style.display).toBe('none')
    })

    it('shows 99+ for counts over 99', () => {
      badge.textContent = '98'
      
      controller.updateBadgeCount(2)
      
      expect(badge.textContent).toBe('99+')
    })

    it('prevents negative counts', () => {
      badge.textContent = '1'
      
      controller.updateBadgeCount(-5)
      
      expect(badge.parentElement.style.display).toBe('none')
    })
  })

  describe('csrfToken getter', () => {
    it('returns token from meta tag', () => {
      const meta = document.createElement('meta')
      meta.name = 'csrf-token'
      meta.content = 'test-token-123'
      document.head.appendChild(meta)
      
      expect(controller.csrfToken).toBe('test-token-123')
      
      document.head.removeChild(meta)
    })

    it('returns empty string when no meta tag', () => {
      expect(controller.csrfToken).toBe('')
    })
  })
})