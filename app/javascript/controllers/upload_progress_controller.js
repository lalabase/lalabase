import { Controller } from "@hotwired/stimulus"
import { DirectUpload } from "@rails/activestorage"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["input", "progress", "progressBar", "status", "submitButton"]
  
  connect() {
    this.boundHandleFileSelect = this.handleFileSelect.bind(this)
    this.inputTarget.addEventListener("change", this.boundHandleFileSelect)
  }

  disconnect() {
    this.inputTarget.removeEventListener("change", this.boundHandleFileSelect)
  }
  
  handleFileSelect(event) {
    const file = event.target.files[0]
    if (!file) return
    
    // Disable submit button until upload completes
    this.submitButtonTarget.disabled = true
    this.submitButtonTarget.textContent = I18n.t('stimulus.upload.please_wait')
    
    // Show progress
    this.progressTarget.classList.remove("hidden")
    this.statusTarget.textContent = I18n.t('stimulus.upload.uploading_file', {filename: file.name, size: this.formatBytes(file.size)})
    
    // Start direct upload
    const upload = new DirectUpload(file, this.data.get("directUploadUrl"), this)
    
    upload.create((error, blob) => {
      if (error) {
        this.statusTarget.textContent = I18n.t('stimulus.upload.error', {error: error})
        this.statusTarget.classList.add("text-red-600")
        this.submitButtonTarget.disabled = false
        this.submitButtonTarget.textContent = I18n.t('stimulus.upload.import_button')
      } else {
        // Store blob signed ID for form submission
        this.createHiddenInput(blob.signed_id)
        this.statusTarget.textContent = I18n.t('stimulus.upload.upload_completed')
        this.statusTarget.classList.add("text-green-600")
        this.submitButtonTarget.disabled = false
        this.submitButtonTarget.textContent = I18n.t('stimulus.upload.import_button')
        this.progressBarTarget.style.width = "100%"
      }
    })
  }
  
  directUploadWillStoreFileWithXHR(request) {
    request.upload.addEventListener("progress", event => this.progressUpdate(event))
  }
  
  progressUpdate(event) {
    const progress = event.loaded / event.total * 100
    this.progressBarTarget.style.width = `${progress}%`
    
    const loaded = this.formatBytes(event.loaded)
    const total = this.formatBytes(event.total)
    this.statusTarget.textContent = I18n.t('stimulus.upload.progress', {loaded: loaded, total: total, percent: Math.round(progress)})
  }
  
  formatBytes(bytes) {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = [I18n.t('stimulus.upload.bytes'), I18n.t('stimulus.upload.kb'), I18n.t('stimulus.upload.mb'), I18n.t('stimulus.upload.gb')]
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]
  }
  
  createHiddenInput(signedId) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = "archive_file_blob_id"
    input.value = signedId
    this.element.appendChild(input)
  }
}