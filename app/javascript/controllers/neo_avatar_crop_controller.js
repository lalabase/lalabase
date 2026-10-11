import { Controller } from '@hotwired/stimulus'

// Frames the circle crop for a freshly picked profile picture
// (doc/user_display_name_avatar_plan.md, crop extension). Pure progressive
// enhancement: without JS the file input submits alone and the server keeps
// its center crop; with JS the picked image appears in a round stage, drag
// pans it, the range input zooms, and three hidden fields carry the framed
// square in ORIGINAL image pixels (naturalWidth/naturalHeight coordinates).
// The stage never shows uncovered background: scale is floored at "cover"
// and offsets are clamped to the image edges, so the submitted rectangle is
// always inside the picture.
export default class extends Controller {
  static targets = ['input', 'editor', 'image', 'zoom', 'fieldX', 'fieldY', 'fieldSize']

  disconnect () {
    // dragEnd too, not only the object URL: dragStart hangs its listeners on
    // WINDOW, so a Turbo visit in the middle of a drag would leave them there,
    // calling render() on a controller whose targets are gone.
    this.dragEnd()
    this.revokeUrl()
  }

  pick () {
    const file = this.inputTarget.files[0]
    this.revokeUrl()
    // Back to zero on EVERY pick, before the new file is even loaded: if the
    // second picture never fires `load` (a broken file, a format this browser
    // cannot decode), the stale fields would submit the FIRST picture's frame
    // together with the second picture's bytes.
    this.reset()
    if (!file || !file.type.startsWith('image/')) return

    this.objectUrl = URL.createObjectURL(file)
    this.imageTarget.src = this.objectUrl
  }

  // img.onload — only now naturalWidth/naturalHeight exist.
  loaded () {
    this.natW = this.imageTarget.naturalWidth
    this.natH = this.imageTarget.naturalHeight
    if (!this.natW || !this.natH) return

    this.editorTarget.hidden = false
    this.zoomTarget.value = this.zoomBounds().min
    this.applyZoom(this.zoomBounds().min, { center: true })
  }

  // img.onerror — the browser could not decode the picked file. The guard
  // keeps reset() from bouncing back here: it clears src, which can itself
  // fire another error.
  failed () {
    if (this.imageTarget.getAttribute('src')) this.reset()
  }

  zoom () {
    this.applyZoom(parseFloat(this.zoomTarget.value) || this.zoomBounds().min)
  }

  dragStart (event) {
    if (!this.scale) return
    event.preventDefault()
    // Capture the pointer so a button released OUTSIDE the window still ends
    // the drag. Without it pointerup never arrives and the picture stays glued
    // to the bare cursor, rewriting the hidden fields with no button held.
    event.currentTarget.setPointerCapture?.(event.pointerId)
    this.dragFrom = { x: event.clientX, y: event.clientY, offX: this.offX, offY: this.offY }
    this.moveHandler = (e) => this.dragMove(e)
    this.endHandler = () => this.dragEnd()
    window.addEventListener('pointermove', this.moveHandler)
    window.addEventListener('pointerup', this.endHandler)
    // pointercancel: the OS took the gesture away (touch scroll, a system
    // dialog). It replaces pointerup, it does not follow it.
    window.addEventListener('pointercancel', this.endHandler)
  }

  dragMove (event) {
    this.offX = this.dragFrom.offX + (event.clientX - this.dragFrom.x)
    this.offY = this.dragFrom.offY + (event.clientY - this.dragFrom.y)
    this.render()
  }

  dragEnd () {
    if (!this.moveHandler) return

    window.removeEventListener('pointermove', this.moveHandler)
    window.removeEventListener('pointerup', this.endHandler)
    window.removeEventListener('pointercancel', this.endHandler)
    this.moveHandler = null
    this.endHandler = null
  }

  // --- internals ---

  // The range input owns its own limits; reading them back keeps one pair of
  // numbers instead of the same 1 and 3 written in the markup and here.
  zoomBounds () {
    return {
      min: parseFloat(this.zoomTarget.min) || 1,
      max: parseFloat(this.zoomTarget.max) || 1
    }
  }

  applyZoom (factor, { center = false } = {}) {
    const stage = this.stageSize()
    const cover = stage / Math.min(this.natW, this.natH)
    const previous = this.scale || cover
    const { min, max } = this.zoomBounds()
    this.scale = cover * Math.min(Math.max(factor, min), max)

    if (center) {
      this.offX = (stage - this.natW * this.scale) / 2
      this.offY = (stage - this.natH * this.scale) / 2
    } else {
      // Keep the stage center pointing at the same image spot while zooming.
      const ratio = this.scale / previous
      this.offX = stage / 2 - (stage / 2 - this.offX) * ratio
      this.offY = stage / 2 - (stage / 2 - this.offY) * ratio
    }
    this.render()
  }

  render () {
    const stage = this.stageSize()
    this.offX = Math.min(0, Math.max(this.offX, stage - this.natW * this.scale))
    this.offY = Math.min(0, Math.max(this.offY, stage - this.natH * this.scale))

    this.imageTarget.style.width = `${this.natW * this.scale}px`
    this.imageTarget.style.maxWidth = 'none'
    this.imageTarget.style.transform = `translate(${this.offX}px, ${this.offY}px)`

    this.fieldXTarget.value = Math.round(-this.offX / this.scale)
    this.fieldYTarget.value = Math.round(-this.offY / this.scale)
    this.fieldSizeTarget.value = Math.round(stage / this.scale)
  }

  stageSize () {
    return this.editorTarget.querySelector('[data-avatar-crop-stage]').clientWidth
  }

  reset () {
    this.editorTarget.hidden = true
    this.imageTarget.removeAttribute('src')
    this.scale = null
    this.natW = null
    this.natH = null
    this.fieldXTarget.value = ''
    this.fieldYTarget.value = ''
    this.fieldSizeTarget.value = ''
  }

  revokeUrl () {
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
    this.objectUrl = null
  }
}
