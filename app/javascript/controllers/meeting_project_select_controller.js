import { Controller } from "@hotwired/stimulus"
import { chosenFormUrl } from "meeting_project_select"

/**
 * Meeting Project Select Controller
 *
 * "Neues Meeting" on "Alle Meetings" opens a project select in the lane
 * (meetings_overview/_new_meeting_lane). The choice loads that project's form
 * into the frame below the select; every <option> carries its address from
 * ERB, and this controller only copies it onto the frame (lib/meeting_project_select).
 *
 * A new choice is a new frame visit, and Turbo cancels the one in flight, so
 * the form of the project chosen before cannot arrive after it. The form that
 * stands there goes at once: the new answer can be a redirect (the right went,
 * the project was deleted), frame-error then only puts its message on top, and
 * the old form would stay under the new name, saving into the old project.
 * Taking the choice back starts no visit: an answer still in flight then
 * renders into the frame, and it is put back to the zero state, or the lane
 * would show a form for a project the select no longer names.
 */
export default class extends Controller {
  static targets = ["select", "frame", "placeholder"]

  connect() {
    this.boundFrameLoaded = this.frameLoaded.bind(this)
    this.frameTarget.addEventListener("turbo:frame-load", this.boundFrameLoaded)
  }

  disconnect() {
    this.frameTarget.removeEventListener("turbo:frame-load", this.boundFrameLoaded)
  }

  choose() {
    const url = chosenFormUrl(this.selectTarget)
    if (url) {
      this.frameTarget.replaceChildren()
      this.frameTarget.setAttribute("src", url)
      return
    }

    this.reset()
  }

  frameLoaded() {
    if (chosenFormUrl(this.selectTarget)) return

    this.reset()
  }

  reset() {
    this.frameTarget.removeAttribute("src")
    this.frameTarget.replaceChildren(this.placeholderTarget.content.cloneNode(true))
  }
}
