import { Controller } from "@hotwired/stimulus"

/**
 * Manages file upload UX for ActiveStorage direct uploads.
 *
 * Listens to native ActiveStorage direct-upload:* DOM events to:
 * - Show per-file progress bars with file name and size
 * - Disable the submit button while uploads are in progress
 * - Re-enable submit once all uploads complete (or on error)
 *
 * ActiveStorage fires events with a numeric id (0, 1, 2...) matching
 * the order of files in the FileList. We use onInitialize to assign
 * each file item its correct upload id.
 */
export default class extends Controller {
  static targets = ["input", "fileList", "submit"]

  connect() {
    this.pendingUploads = 0
    this.initIndex = 0

    // Save bound references for proper cleanup
    this.boundOnInitialize = this.onInitialize.bind(this)
    this.boundOnStart = this.onStart.bind(this)
    this.boundOnProgress = this.onProgress.bind(this)
    this.boundOnError = this.onError.bind(this)
    this.boundOnEnd = this.onEnd.bind(this)

    this.element.addEventListener("direct-upload:initialize", this.boundOnInitialize)
    this.element.addEventListener("direct-upload:start", this.boundOnStart)
    this.element.addEventListener("direct-upload:progress", this.boundOnProgress)
    this.element.addEventListener("direct-upload:error", this.boundOnError)
    this.element.addEventListener("direct-upload:end", this.boundOnEnd)
  }

  disconnect() {
    this.element.removeEventListener("direct-upload:initialize", this.boundOnInitialize)
    this.element.removeEventListener("direct-upload:start", this.boundOnStart)
    this.element.removeEventListener("direct-upload:progress", this.boundOnProgress)
    this.element.removeEventListener("direct-upload:error", this.boundOnError)
    this.element.removeEventListener("direct-upload:end", this.boundOnEnd)
  }

  filesSelected() {
    const files = this.inputTarget.files
    if (!files.length) return

    this.fileListTarget.classList.remove("hidden")
    this.fileListTarget.innerHTML = ""
    this.initIndex = 0

    for (let i = 0; i < files.length; i++) {
      this.fileListTarget.insertAdjacentHTML("beforeend", this.fileItemHTML(files[i], i))
    }
  }

  onInitialize(event) {
    const { id } = event.detail
    // Assign the ActiveStorage upload id to the pre-rendered file item
    const items = this.fileListTarget.querySelectorAll("[data-upload-index]")
    const item = items[this.initIndex]
    if (item) item.setAttribute("data-upload-id", id)
    this.initIndex++

    this.pendingUploads++
    this.disableSubmit()
  }

  onStart(event) {
    const bar = this.findElement(event.detail.id, ".upload-progress-bar")
    if (bar) bar.style.width = "0%"
  }

  onProgress(event) {
    const { id, progress } = event.detail
    const bar = this.findElement(id, ".upload-progress-bar")
    if (bar) bar.style.width = `${progress}%`

    const pct = this.findElement(id, ".upload-percent")
    if (pct) pct.textContent = `${Math.round(progress)}%`
  }

  onError(event) {
    event.preventDefault()
    const { id } = event.detail
    const item = this.element.querySelector(`[data-upload-id="${id}"]`)
    if (item) {
      item.classList.add("text-red-600")
      const pct = item.querySelector(".upload-percent")
      if (pct) pct.textContent = "Fehler"
    }
    this.pendingUploads--
    if (this.pendingUploads <= 0) this.enableSubmit()
  }

  onEnd(event) {
    const { id } = event.detail
    const bar = this.findElement(id, ".upload-progress-bar")
    if (bar) {
      bar.style.width = "100%"
      bar.classList.remove("bg-lime-400")
      bar.classList.add("bg-lime-500")
    }
    const pct = this.findElement(id, ".upload-percent")
    if (pct) pct.textContent = "\u2713"

    this.pendingUploads--
    if (this.pendingUploads <= 0) this.enableSubmit()
  }

  // --- private ---

  findElement(uploadId, selector) {
    const item = this.element.querySelector(`[data-upload-id="${uploadId}"]`)
    return item ? item.querySelector(selector) : null
  }

  disableSubmit() {
    if (!this.hasSubmitTarget) return
    this.submitTarget.disabled = true
    this.submitTarget.classList.add("opacity-50", "cursor-not-allowed")
  }

  enableSubmit() {
    if (!this.hasSubmitTarget) return
    this.submitTarget.disabled = false
    this.submitTarget.classList.remove("opacity-50", "cursor-not-allowed")
  }

  fileItemHTML(file, index) {
    const name = file.name.length > 30 ? file.name.substring(0, 27) + "..." : file.name
    const size = this.formatBytes(file.size)

    return `
      <div class="flex items-center gap-2 py-1" data-upload-index="${index}">
        <i class="bi bi-file-earmark text-gray-500" style="font-size: 14px;"></i>
        <span class="text-sm truncate flex-1">${this.escapeHTML(name)} <span class="text-gray-400">(${size})</span></span>
        <span class="upload-percent text-xs text-gray-400 w-8 text-right"></span>
        <div class="w-20 h-1.5 bg-gray-200 rounded-full overflow-hidden">
          <div class="upload-progress-bar h-full bg-lime-400 rounded-full transition-all duration-200" style="width: 0%"></div>
        </div>
      </div>
    `
  }

  escapeHTML(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  formatBytes(bytes) {
    if (bytes === 0) return "0 B"
    const k = 1024
    const sizes = ["B", "KB", "MB", "GB"]
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + " " + sizes[i]
  }
}
