import { Controller } from "@hotwired/stimulus"
import { zoomLinkFor } from "rich_text_zoom"

// Lightbox for images inside rendered rich texts (spike plan Inline-Bilder, Paket 2,
// P2-E2). Sits on the content wrapper (layouts/action_text/contents/_content.html.erb),
// never on the image: ActionText sanitizes the attachment partials after rendering and
// strips data attributes, and Turbo Streams replace the content without re-running
// markup hooks. The zoom target is the `a.attachment__zoom` the blob partial renders;
// without JavaScript that link opens the large variant on its own.
export default class extends Controller {
  connect() {
    // Turbo snapshots the body BEFORE Stimulus disconnects, and the dialog hangs on
    // document.body, not on this.element. Without this, a browser Back with the lightbox
    // open caches the page WITH an open <dialog> and the way back shows a stale full-size
    // image (ticket pages are cached; only a few index views opt out via
    // <meta name="turbo-cache-control">).
    this.closeForCache = () => this.close()
    document.addEventListener("turbo:before-cache", this.closeForCache)
  }

  open(event) {
    const link = zoomLinkFor(event.target, this.element, event)
    if (!link) return

    event.preventDefault()
    // Describe the picture, not the link: the title says what clicking does ("enlarge
    // image"), the img alt carries the filename.
    this.show(link.getAttribute("href"), link.querySelector("img")?.getAttribute("alt") || "")
  }

  show(src, alt) {
    this.close()
    const dialog = document.createElement("dialog")
    dialog.className = "rich-text-zoom"
    dialog.setAttribute("aria-label", alt)

    const image = document.createElement("img")
    image.src = src
    image.alt = alt
    image.className = "rich-text-zoom__image"
    dialog.appendChild(image)

    const close = document.createElement("button")
    close.type = "button"
    close.className = "rich-text-zoom__close"
    close.setAttribute("aria-label", this.element.dataset.zoomCloseLabel || "×")
    close.textContent = "×"
    close.addEventListener("click", () => this.close())
    dialog.appendChild(close)

    // Backdrop click closes; clicks on the image itself do not.
    dialog.addEventListener("click", (e) => { if (e.target === dialog) this.close() })
    dialog.addEventListener("close", () => dialog.remove())

    document.body.appendChild(dialog)
    this.dialog = dialog
    dialog.showModal()
  }

  close() {
    if (!this.dialog) return
    if (this.dialog.open) this.dialog.close()
    this.dialog.remove()
    this.dialog = null
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.closeForCache)
    this.close()
  }
}
