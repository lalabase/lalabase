import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]
  
  connect() {
    // Only show on mobile
    if (window.innerWidth < 640) {
      this.showThreshold = 300
      this.boundHandleScroll = this.handleScroll.bind(this)
      window.addEventListener("scroll", this.boundHandleScroll)
      this.handleScroll() // Check initial state
    } else {
      this.element.style.display = 'none'
    }
  }

  disconnect() {
    if (this.boundHandleScroll) {
      window.removeEventListener("scroll", this.boundHandleScroll)
    }
  }
  
  handleScroll() {
    if (window.pageYOffset > this.showThreshold) {
      this.showButton()
    } else {
      this.hideButton()
    }
  }
  
  showButton() {
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.remove("hidden")
      this.buttonTarget.classList.add("flex")
    }
  }
  
  hideButton() {
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.add("hidden")
      this.buttonTarget.classList.remove("flex")
    }
  }
  
  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({
      top: 0,
      behavior: 'smooth'
    })
  }
}