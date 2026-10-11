import { Controller } from "@hotwired/stimulus"

// Keeps the running conversation in view. The composer sits BELOW the message
// log, so everything new grows upward out of the viewport and the reader had to
// scroll back by hand.
//
// Two acts, in this order:
//
//   1. THE JUMP. When this tab's own composer submit succeeds, the next post
//      appended to the log is scrolled to the top of the viewport -- the
//      question you just asked stays visible and the answer streams below it.
//   2. THE FOLLOW. From then on, every further change in the log (the assistant
//      placeholder, and then one render per streamed token) keeps the END of the
//      transcript visible. It only ever scrolls when the end has actually run
//      off the bottom, so the jump above is not undone while the answer is still
//      short enough to fit.
//
// Both are armed ONLY by the composer's own turbo:submit-end: appends broadcast
// to OTHER viewers of the shared chat stream must never move their scroll
// position, and regenerate pills / delete forms bubble submit-end through this
// frame too.
//
// The follow stops the moment you scroll UP yourself -- recognised without a
// scroll listener, by comparing where the container stands against where this
// controller last put it. A programmatic scroll fires the same events a real one
// does, so a listener could not tell the two apart; a remembered position can.
// Scrolling further DOWN is not a reason to stop, and neither is anything the
// controller did itself. Sending the next message arms both acts again.
const ARM_WINDOW_MS = 8000

// How far the container may drift upward from where we put it before we read it
// as "the reader took over". Small, but not zero: browsers round scrollTop, and
// a growing transcript can shift it by a pixel on its own.
const DRIFT_PX = 8

export default class extends Controller {
  static targets = ["log"]

  connect() {
    this.armedUntil = 0
    this.following = false
    this.followScheduled = false
    this.expectedTop = null
    this.scroller = null
    if (!this.hasLogTarget) return

    // subtree + characterData as well as childList: a streamed answer arrives as
    // turbo_stream replacements of ONE post, and depending on how much of the
    // element Turbo swaps that is not always a childList change on the log.
    this.observer = new MutationObserver((mutations) => this.onLogChanged(mutations))
    this.observer.observe(this.logTarget, { childList: true, subtree: true, characterData: true })
  }

  disconnect() {
    this.observer?.disconnect()
    this.following = false
  }

  arm(event) {
    if (!event.detail?.success) return
    if (!event.target.matches?.('[data-controller~="neo-chat-composer"]')) return

    this.armedUntil = performance.now() + ARM_WINDOW_MS
    // Resolved here and not per tick: the follow runs at the rate of a streamed
    // answer, and walking the ancestor chain with getComputedStyle sixty times a
    // second for a container that cannot change mid-answer is pure waste.
    this.scroller = this.findScroller()
  }

  onLogChanged(mutations) {
    if (this.jumpToAddedPost(mutations)) return
    if (this.following) this.scheduleFollow()
  }

  // Act 1. Returns true when it handled this batch, so the follow does not
  // immediately scroll away from the post we just put at the top.
  jumpToAddedPost(mutations) {
    if (performance.now() > this.armedUntil) return false

    // Direct children of the log only: a change INSIDE an existing bubble is the
    // answer streaming, not a new post arriving.
    const added = mutations
      .filter((mutation) => mutation.target === this.logTarget)
      .flatMap((mutation) => [...mutation.addedNodes])
      .find((node) => node.nodeType === Node.ELEMENT_NODE)
    if (!added) return false

    // Disarm before the (async) scroll: the assistant placeholder appends right
    // after the user post and must not trigger a second jump. From here on the
    // follow has the wheel.
    this.armedUntil = 0
    this.following = true
    requestAnimationFrame(() => {
      // Instant, NOT smooth. A smooth jump keeps moving for a few hundred
      // milliseconds, and the follow that starts right after it would have to
      // ignore the container for that long -- which is exactly long enough for a
      // reader who scrolls up in that window to be dragged back down, because
      // there was no reference position to recognise them by. Instant gives the
      // follow a truthful starting point on the very next line, and the jump
      // itself is short anyway: the post it scrolls to was just appended at the
      // end the reader was already looking at.
      added.scrollIntoView({ block: "start" })
      this.expectedTop = this.scrollTop()
    })
    return true
  }

  // One follow per frame at most. A streamed answer rewrites its bubble once per
  // token, and each of those is a mutation batch.
  scheduleFollow() {
    if (this.followScheduled) return

    this.followScheduled = true
    requestAnimationFrame(() => {
      this.followScheduled = false
      this.follow()
    })
  }

  // Act 2.
  follow() {
    const top = this.scrollTop()
    const max = this.maxScrollTop()
    if (top === null) return

    // Scrolled up since we last looked: the reader took over, and the answer can
    // keep arriving without moving anything under their eyes.
    if (this.expectedTop !== null && top < this.expectedTop - DRIFT_PX) {
      this.following = false
      return
    }

    // The end is still visible: nothing to do but remember where we are. This is
    // what keeps the freshly asked question at the top while a short answer
    // arrives underneath it.
    if (top >= max - DRIFT_PX) {
      this.expectedTop = top
      return
    }

    this.scrollTo(max)
    this.expectedTop = this.scrollTop()
  }

  // The element that actually scrolls the transcript: the log itself in the
  // companion panel (assistant_panel.css gives it overflow-y: auto), the window
  // on a chat page, where the card just grows. Walking up rather than knowing
  // either of them by name -- a selector that repeats an identifier defined
  // somewhere else is how the panel's own CSS broke twice.
  findScroller() {
    let node = this.logTarget
    while (node && node !== document.body) {
      const overflowY = getComputedStyle(node).overflowY
      if (/(auto|scroll)/.test(overflowY) && node.scrollHeight > node.clientHeight) return node

      node = node.parentElement
    }
    return null
  }

  scrollTop() {
    if (this.scroller) return this.scroller.scrollTop
    if (!this.hasLogTarget) return null

    return window.scrollY
  }

  maxScrollTop() {
    if (this.scroller) return this.scroller.scrollHeight - this.scroller.clientHeight

    return document.documentElement.scrollHeight - window.innerHeight
  }

  scrollTo(top) {
    if (this.scroller) {
      this.scroller.scrollTop = top
      return
    }
    // No smooth here, deliberately: at one render per token a smooth scroll never
    // reaches its destination before the next one starts and the transcript
    // visibly lags behind the text arriving in it.
    window.scrollTo(0, top)
  }
}
