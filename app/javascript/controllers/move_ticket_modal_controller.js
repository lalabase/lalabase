import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "projectSelect", "impactFrame", "submitButton", "hiddenProjectId"]

  connect() {
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("keydown", this.boundCloseOnEscape)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundCloseOnEscape)
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")

    // Reset select and impact area
    if (this.hasProjectSelectTarget) {
      this.projectSelectTarget.value = ""
    }
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }
    if (this.hasImpactFrameTarget) {
      this.impactFrameTarget.innerHTML = ""
      this.impactFrameTarget.removeAttribute("src")
    }
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) {
      this.close()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  projectChanged() {
    const projectId = this.projectSelectTarget.value

    // Sync hidden field for form submission
    if (this.hasHiddenProjectIdTarget) {
      this.hiddenProjectIdTarget.value = projectId || ""
    }

    if (projectId) {
      // Enable submit button
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false
      }

      // Update turbo frame src to load impact preview
      if (this.hasImpactFrameTarget) {
        const baseUrl = this.element.dataset.moveTicketModalPreflightUrl
        this.impactFrameTarget.src = `${baseUrl}?target_project_id=${projectId}`
      }
    } else {
      // Disable submit button and clear impact
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = true
      }
      if (this.hasImpactFrameTarget) {
        this.impactFrameTarget.innerHTML = ""
        this.impactFrameTarget.removeAttribute("src")
      }
    }
  }
}
