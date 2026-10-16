import { Controller } from "@hotwired/stimulus"
import { listAddress } from "list_address"

/**
 * List Address Controller
 *
 * Keeps the address of a list page without a lane ("Alle Meetings") equal to
 * the list it shows. Whenever the list frame is loaded (filter bar, column head,
 * page link) or replaced by a stream (a save from the "+" modal), the address
 * becomes the page's path with the state the frame rendered. The entry is
 * replaced, not added, and keeps its history state; lane:list-changed tells
 * index-page which list part the page now shows (its Back/Forward restorer).
 *
 * Values:
 *   frame  the id of the list frame
 *   path   the page's path, without query
 */
export default class extends Controller {
  static values = { frame: String, path: String }

  connect() {
    this.handleFrameLoad = this.handleFrameLoad.bind(this)
    this.handleStream = this.handleStream.bind(this)
    document.addEventListener("turbo:frame-load", this.handleFrameLoad)
    document.addEventListener("turbo:before-stream-render", this.handleStream)
  }

  disconnect() {
    document.removeEventListener("turbo:frame-load", this.handleFrameLoad)
    document.removeEventListener("turbo:before-stream-render", this.handleStream)
  }

  handleFrameLoad(event) {
    if (event.target.id === this.frameValue) this.sync()
  }

  handleStream(event) {
    if (event.target.getAttribute("target") !== this.frameValue) return

    const render = event.detail.render
    event.detail.render = async (stream) => {
      await render(stream)
      this.sync()
    }
  }

  sync() {
    const frame = document.getElementById(this.frameValue)
    const state = frame && frame.querySelector("[data-list-filter-query]")
    const address = listAddress(this.pathValue, state ? state.dataset.listFilterQuery : undefined)
    if (!address) return

    window.history.replaceState(window.history.state || { lane: true }, "", address)
    this.element.dispatchEvent(new CustomEvent("lane:list-changed", { bubbles: true }))
  }
}
