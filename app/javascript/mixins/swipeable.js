// Swipeable Mixin for Stimulus Controllers
//
// Adds swipe gesture detection to any Stimulus controller
// Usage:
//   import Swipeable from 'mixins/swipeable'  // bare specifier (pinned in importmap.rb) — NOT relative
//   
//   export default class extends Controller {
//     connect() {
//       Object.assign(this, Swipeable)
//       this.initializeSwipe()
//     }
//     
//     onSwipeLeft() { /* handle left swipe */ }
//     onSwipeRight() { /* handle right swipe */ }
//   }

const Swipeable = {
  // Configuration
  swipeThreshold: 100, // minimum distance for swipe in pixels
  swipeVelocityThreshold: 0.3, // minimum velocity for quick swipes
  swipeAngleThreshold: 30, // maximum angle deviation from horizontal
  
  // State
  touchStartX: 0,
  touchStartY: 0,
  touchStartTime: 0,
  touchCurrentX: 0,
  touchCurrentY: 0,
  isDragging: false,
  swipeDirection: null,
  
  initializeSwipe() {
    // Store bound handlers for proper cleanup
    this.boundHandleTouchStart = this.handleTouchStart.bind(this)
    this.boundHandleTouchMove = this.handleTouchMove.bind(this)
    this.boundHandleTouchEnd = this.handleTouchEnd.bind(this)
    this.boundHandleTouchCancel = this.handleTouchCancel.bind(this)
    
    // Add touch event listeners
    this.element.addEventListener('touchstart', this.boundHandleTouchStart, { passive: true })
    this.element.addEventListener('touchmove', this.boundHandleTouchMove, { passive: false })
    this.element.addEventListener('touchend', this.boundHandleTouchEnd, { passive: true })
    this.element.addEventListener('touchcancel', this.boundHandleTouchCancel, { passive: true })
    
    // Add CSS class for styling
    this.element.classList.add('swipeable')
    
    // Store original transform for reset
    this.originalTransform = getComputedStyle(this.element).transform
    if (this.originalTransform === 'none') {
      this.originalTransform = ''
    }
  },
  
  handleTouchStart(event) {
    // Ignore multi-touch
    if (event.touches.length > 1) return
    
    const touch = event.touches[0]
    this.touchStartX = touch.clientX
    this.touchStartY = touch.clientY
    this.touchStartTime = Date.now()
    this.touchCurrentX = touch.clientX
    this.touchCurrentY = touch.clientY
    this.isDragging = true
    this.swipeDirection = null
    
    // Add dragging class for CSS
    this.element.classList.add('swiping')
    
    // Optional: Call handler if defined
    if (this.onSwipeStart) {
      this.onSwipeStart(event)
    }
  },
  
  handleTouchMove(event) {
    if (!this.isDragging) return
    
    const touch = event.touches[0]
    this.touchCurrentX = touch.clientX
    this.touchCurrentY = touch.clientY
    
    const deltaX = this.touchCurrentX - this.touchStartX
    const deltaY = this.touchCurrentY - this.touchStartY
    
    // Check if this is a horizontal swipe
    const angle = Math.abs(Math.atan2(deltaY, deltaX) * 180 / Math.PI)
    const isHorizontal = angle <= this.swipeAngleThreshold || angle >= (180 - this.swipeAngleThreshold)
    
    if (!isHorizontal) {
      // Not a horizontal swipe, let vertical scroll happen
      this.cancelSwipe()
      return
    }
    
    // Prevent default to stop scrolling
    event.preventDefault()
    
    // Determine swipe direction
    if (!this.swipeDirection) {
      this.swipeDirection = deltaX > 0 ? 'right' : 'left'
    }
    
    // Apply visual feedback
    this.updateSwipeVisual(deltaX)
    
    // Optional: Call handler if defined
    if (this.onSwipeMove) {
      this.onSwipeMove(deltaX, deltaY)
    }
  },
  
  handleTouchEnd(event) {
    if (!this.isDragging) return
    
    const deltaX = this.touchCurrentX - this.touchStartX
    const deltaY = this.touchCurrentY - this.touchStartY
    const deltaTime = Date.now() - this.touchStartTime
    const velocity = Math.abs(deltaX / deltaTime)
    
    // Check if this qualifies as a swipe
    const isSwipe = Math.abs(deltaX) > this.swipeThreshold || 
                    (velocity > this.swipeVelocityThreshold && Math.abs(deltaX) > 50)
    
    if (isSwipe) {
      // Trigger swipe action
      if (deltaX > 0) {
        this.triggerSwipeRight()
      } else {
        this.triggerSwipeLeft()
      }
    } else {
      // Reset position
      this.resetSwipeVisual()
    }
    
    this.cleanupSwipe()
  },
  
  handleTouchCancel(event) {
    if (this.isDragging) {
      this.resetSwipeVisual()
      this.cleanupSwipe()
    }
  },
  
  updateSwipeVisual(deltaX) {
    // Apply transform with resistance at edges
    const resistance = Math.abs(deltaX) > 200 ? 0.3 : 1
    const translateX = deltaX * resistance
    
    // Apply transform
    requestAnimationFrame(() => {
      this.element.style.transform = `translateX(${translateX}px)`
      
      // Optional: Apply opacity based on distance
      const opacity = Math.max(0.3, 1 - Math.abs(translateX) / 300)
      this.element.style.opacity = opacity
    })
  },
  
  resetSwipeVisual() {
    this.element.style.transition = 'transform 0.3s ease-out, opacity 0.3s ease-out'
    this.element.style.transform = this.originalTransform
    this.element.style.opacity = '1'
    
    setTimeout(() => {
      this.element.style.transition = ''
    }, 300)
  },
  
  triggerSwipeLeft() {
    // Animate out
    this.element.style.transition = 'transform 0.3s ease-out, opacity 0.3s ease-out'
    this.element.style.transform = 'translateX(-100%)'
    this.element.style.opacity = '0'
    
    // Call handler if defined
    if (this.onSwipeLeft) {
      // Delay to allow animation
      setTimeout(() => {
        this.onSwipeLeft()
      }, 150)
    }
  },
  
  triggerSwipeRight() {
    // Animate out
    this.element.style.transition = 'transform 0.3s ease-out, opacity 0.3s ease-out'
    this.element.style.transform = 'translateX(100%)'
    this.element.style.opacity = '0'
    
    // Call handler if defined
    if (this.onSwipeRight) {
      // Delay to allow animation
      setTimeout(() => {
        this.onSwipeRight()
      }, 150)
    }
  },
  
  cancelSwipe() {
    this.resetSwipeVisual()
    this.cleanupSwipe()
  },
  
  cleanupSwipe() {
    this.isDragging = false
    this.swipeDirection = null
    this.element.classList.remove('swiping')
    
    // Optional: Call handler if defined
    if (this.onSwipeEnd) {
      this.onSwipeEnd()
    }
  },
  
  // Public method to disable swipe
  disableSwipe() {
    if (this.boundHandleTouchStart) {
      this.element.removeEventListener('touchstart', this.boundHandleTouchStart)
      this.element.removeEventListener('touchmove', this.boundHandleTouchMove)
      this.element.removeEventListener('touchend', this.boundHandleTouchEnd)
      this.element.removeEventListener('touchcancel', this.boundHandleTouchCancel)
      
      // Clean up references
      this.boundHandleTouchStart = null
      this.boundHandleTouchMove = null
      this.boundHandleTouchEnd = null
      this.boundHandleTouchCancel = null
    }
    
    this.element.classList.remove('swipeable')
  }
}

export default Swipeable