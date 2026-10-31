import { Controller } from "@hotwired/stimulus"

// Sends a link to another ticket out of the inbox pane.
//
// The pane is a quick look at ONE notification. Its head (who assigned you, read and archive,
// "open in ticket") belongs to that notification, and only the part below it is a frame. A
// link that stays in the frame swaps that part and leaves the head naming the old ticket, so
// a click on "open in ticket" lands on another ticket than the one on screen.
//
// A controller rather than a target on each link: the timeline, which holds the sub-task
// list, loads apart and cannot know that it sits in the pane. Links mark themselves with
// data-ticket-link; on every other page nothing listens. The click bubbles here before it
// reaches Turbo on the document, so the target is in place when Turbo reads it.
export default class extends Controller {
  leave(event) {
    const link = event.target.closest("a[data-ticket-link]")
    if (link) link.dataset.turboFrame = "_top"
  }
}
