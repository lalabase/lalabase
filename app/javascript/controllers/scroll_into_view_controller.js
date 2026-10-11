import { Controller } from "@hotwired/stimulus"

/**
 * Scroll Into View Controller
 *
 * A jump to another part of the page that leaves the address alone. A native #anchor
 * pushes a history entry: on a lane page Back then counts as a lane change and reloads the
 * lane (a comment draft is gone), and the hash rides along into addresses built from
 * window.location (review round 4 of #944).
 *
 * Mount it on a button: data-scroll-into-view-target-value names the id to go to. The
 * target gets the focus as well, so a keyboard or screen reader user lands there too.
 */
export default class extends Controller {
  static values = { target: String }

  scroll(event) {
    event.preventDefault()
    const target = document.getElementById(this.targetValue)
    if (!target) return

    target.scrollIntoView({ block: "start", behavior: "smooth" })
    // Focusable for this jump only: left in place, the target would take the focus of every
    // click inside it (Safari does not focus links on click). Only a tabindex set here goes.
    if (!target.hasAttribute("tabindex")) {
      target.setAttribute("tabindex", "-1")
      target.addEventListener("blur", () => target.removeAttribute("tabindex"), { once: true })
    }
    target.focus({ preventScroll: true })
  }
}
