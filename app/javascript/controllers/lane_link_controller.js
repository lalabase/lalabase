import { Controller } from "@hotwired/stimulus"
import { detailAddress, FULL_PAGE_BELOW_PX } from "list_row/address"
import { readLaneParams, laneParamNames, withLaneState } from "lane/params"

// A link that moves the LANE to a state of the open object: the file name in a
// version row opens the preview, the preview head's way back returns to the
// document (D2 of doc/dateivorschau_plan.md). Two addresses, both built at
// click time from the address bar, so a filter changed after the row was
// rendered is not written back: the page address is the current one with the
// state set or removed, the frame address is the resource this link names with
// the live query. Below the width where the lane would cover the list, a visit
// to the page address, as the row does; the href is the server's plain fallback
// for a page without JavaScript.
//
// Values:
//   url     the resource the frame fetches (/documents/D/preview?version_id=V, /documents/D)
//   frame   the lane's frame
//   set     the lane state to write   ({ preview: "V" })
//   remove  the lane state to take away (["preview"])
//   focus   a selector to focus once the frame has loaded (the way back returns
//           the focus to the file name that opened the preview, D10)
export default class extends Controller {
  static values = {
    url: String,
    frame: String,
    set: { type: Object, default: {} },
    remove: { type: Array, default: [] },
    focus: { type: String, default: "" }
  }

  click(event) {
    // A modified click (a new tab, a new window) is the browser's: the href is
    // the page state, so the browser opens the same state on its own.
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
    event.preventDefault()

    const groups = readLaneParams(this.element)
    const address = withLaneState(new URL(window.location.href), { set: this.setValue, remove: this.removeValue })

    if (window.innerWidth < FULL_PAGE_BELOW_PX) {
      window.location.href = address.toString()
      return
    }

    window.history.pushState({ lane: true }, "", address.toString())

    const frame = document.getElementById(this.frameValue)
    if (!frame) return
    if (this.focusValue) this.focusAfterLoad(frame, this.focusValue)
    frame.setAttribute("src", detailAddress({ url: this.urlValue, current: address, frame: this.frameValue, params: laneParamNames(groups) }))
  }

  focusAfterLoad(frame, selector) {
    const once = (event) => {
      if (event.target !== frame) return
      document.removeEventListener("turbo:frame-load", once)
      const target = frame.querySelector(selector)
      if (target) target.focus()
    }
    document.addEventListener("turbo:frame-load", once)
  }
}
