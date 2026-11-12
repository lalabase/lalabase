import { Controller } from "@hotwired/stimulus"
import { currentSection } from "page_outline"

// The outline of a long page (shared/_page_outline): a list of links to the
// page's sections that marks the one the reader is in.
//
// The links are plain #anchors and work without this controller: the jump, the
// address and Back are the browser's (or Turbo's, which follows a link to an anchor
// of the same page itself). All that is added here is the mark,
// aria-current="location" on one link; the look of it is CSS
// (components/page_outline.css). The script flips an attribute and paints nothing.
//
// Which section is current is decided in lib/page_outline.js (node-tested). This
// controller measures: the sections' top edges on every scroll (once per frame),
// whether the page is at its end, and which link the reader chose last. A choice
// is dropped as soon as the reader scrolls on by hand (wheel, touch, keys); a
// scroll the jump itself causes must not drop it, which is why "scroll" alone
// cannot be the signal.
//
// ⚠️ Not for a page with a lane (tickets, knowledge, meetings): there a #anchor
// pushes a history entry that reads as a lane change. Use scroll_into_view there.
export default class extends Controller {
  static targets = ["link"]
  // How far below the top of the window a section counts as reached: a little
  // more than the sections' scroll margin (scroll-mt-20, 80px), so the section a
  // jump lands on is the current one.
  static values = { line: { type: Number, default: 96 } }

  connect() {
    this.chosen = this.#indexOfHash(window.location.hash)
    this.schedule = this.#schedule.bind(this)
    this.release = this.#release.bind(this)
    this.adoptHash = this.#adoptHash.bind(this)

    // capture: a scroll event does not bubble, and the page may scroll in a box.
    document.addEventListener("scroll", this.schedule, { capture: true, passive: true })
    window.addEventListener("resize", this.schedule, { passive: true })
    window.addEventListener("hashchange", this.adoptHash)
    for (const type of ["wheel", "touchmove", "keydown"]) {
      window.addEventListener(type, this.release, { passive: true })
    }
    this.update()
  }

  disconnect() {
    cancelAnimationFrame(this.frame)
    document.removeEventListener("scroll", this.schedule, { capture: true })
    window.removeEventListener("resize", this.schedule)
    window.removeEventListener("hashchange", this.adoptHash)
    for (const type of ["wheel", "touchmove", "keydown"]) {
      window.removeEventListener(type, this.release)
    }
  }

  // A click on a link: the browser jumps, this remembers what was chosen.
  jump(event) {
    this.chosen = this.linkTargets.indexOf(event.currentTarget)
    this.#schedule()
  }

  update() {
    const sections = this.linkTargets.map((link) => this.#sectionOf(link))
    const page = document.documentElement
    const index = currentSection({
      // A link whose section is missing can never be current.
      tops: sections.map((section) => (section ? section.getBoundingClientRect().top : Infinity)),
      line: this.lineValue,
      atEnd: window.innerHeight + window.scrollY >= page.scrollHeight - 2,
      chosen: this.chosen,
      height: window.innerHeight
    })

    this.linkTargets.forEach((link, position) => {
      if (position === index) {
        link.setAttribute("aria-current", "location")
      } else {
        link.removeAttribute("aria-current")
      }
    })
  }

  #schedule() {
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.update())
  }

  #release() {
    this.chosen = null
  }

  // ⚠️ The hash is read from the EVENT, not from window.location. Turbo follows a
  // link to an anchor of the same page itself and reports it with a hashchange of its
  // own BEFORE it changes the address: at that moment window.location still names the
  // place the reader came from, and the mark went back to the section they had just
  // left (found in the browser, 2026-11-12). The event names where it is going.
  #adoptHash(event) {
    const hash = event?.newURL ? new URL(event.newURL).hash : window.location.hash
    this.chosen = this.#indexOfHash(hash)
    this.#schedule()
  }

  #indexOfHash(hash) {
    if (!hash) return null
    const index = this.linkTargets.findIndex((link) => link.hash === hash)
    return index === -1 ? null : index
  }

  #sectionOf(link) {
    return document.getElementById(decodeURIComponent(link.hash.slice(1)))
  }
}
