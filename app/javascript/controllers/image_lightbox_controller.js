import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay"]
  
  connect() {
    // Image lightbox controller connected
  }
  
  showOverlay() {
    this.overlayTarget.style.opacity = "1"
  }
  
  hideOverlay() {
    this.overlayTarget.style.opacity = "0"
  }
  
  openLightbox(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const imageUrl = event.currentTarget.dataset.imageUrl
    const filename = event.currentTarget.dataset.filename
    
    // Create lightbox modal
    const modal = document.createElement('div')
    modal.className = 'lightbox-modal'
    modal.style.cssText = 'position: fixed; top: 0; left: 0; right: 0; bottom: 0; background-color: rgba(0, 0, 0, 0.9); display: flex; align-items: center; justify-content: center; z-index: 50; padding: 20px;'
    
    modal.innerHTML = `
      <div style="position: relative; max-width: 90vw; max-height: 90vh;">
        <button onclick="this.closest('.lightbox-modal').remove(); document.body.style.overflow = '';" 
                style="position: absolute; top: -40px; right: -40px; width: 40px; height: 40px; background-color: rgba(255, 255, 255, 0.1); border: none; color: white; font-size: 24px; cursor: pointer; border-radius: 50%; display: flex; align-items: center; justify-content: center;">
          <i class="bi bi-x-lg"></i>
        </button>
        <img src="${imageUrl}" 
             alt="${filename}" 
             style="max-width: 100%; max-height: 90vh; object-fit: contain; border-radius: 8px;">
        <div style="position: absolute; bottom: -30px; left: 0; right: 0; text-align: center; color: white; font-size: 14px; opacity: 0.8;">
          ${filename}
        </div>
      </div>
    `
    
    // Click outside to close
    modal.addEventListener('click', (e) => {
      if (e.target === modal) {
        this.closeLightbox(modal)
      }
    })
    
    // ESC key to close
    this.boundEscHandler = (e) => {
      if (e.key === 'Escape') {
        this.closeLightbox(modal)
      }
    }
    document.addEventListener('keydown', this.boundEscHandler)
    
    // Add to DOM
    document.body.appendChild(modal)
    document.body.style.overflow = 'hidden'
  }
  
  closeLightbox(modal) {
    if (modal) {
      modal.remove()
      document.body.style.overflow = ''
    }
    if (this.boundEscHandler) {
      document.removeEventListener('keydown', this.boundEscHandler)
      this.boundEscHandler = null
    }
  }

  disconnect() {
    if (this.boundEscHandler) {
      document.removeEventListener('keydown', this.boundEscHandler)
      this.boundEscHandler = null
    }
  }
}