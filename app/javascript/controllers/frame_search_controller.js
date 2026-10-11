import { Controller } from "@hotwired/stimulus"

// Debounced live search against a Turbo frame (recent_tickets widget, in-app help,
// project docs): it sets the target frame's `src` so only the result list swaps,
// while the input (which lives OUTSIDE the frame) keeps its focus and text.
//
// The documentation/help variant ALSO live-highlights the search term in the open
// page's body while you type (highlight-selector value → the prose container). It
// uses the CSS Custom Highlight API: it marks text RANGES via CSS.highlights, so it
// never touches the server-rendered HTML and clears instantly. Browsers without the
// API (very old) simply show no highlight — search itself keeps working.
//
// The same two surfaces (help + project docs, NOT the widget) also get keyboard
// navigation (combobox pattern): focus stays IN the input, arrow keys move a purely
// visual selection across the result cards (aria-activedescendant + aria-selected),
// Enter opens the selected card exactly like a click. It is opt-in via role="combobox"
// on the input — the recent-tickets widget wires no such role, so every branch below
// stays inert for it.
const DEBOUNCE_MS = 300
const MIN_QUERY_LENGTH = 2
const HIGHLIGHT_NAME = "doc-search"
// Enter navigates the whole page (_top), so the DOM focus is lost. This per-frame
// sessionStorage flag tells the NEXT render to refocus the input and reselect the
// opened card, so the user can keep arrowing without clicking back in. A mouse click
// deliberately does NOT set it, so a click never steals focus after navigation.
const RESUME_KEY_PREFIX = "frame-search-resume:"

export default class extends Controller {
  // `clear`, `result` and `highlightSelector` are OPTIONAL: only the documentation/
  // help sidebar search wires them; the recent-tickets widget has none, so the clear
  // logic, the highlighting AND the keyboard navigation are all guarded.
  static targets = ["input", "clear", "result"]
  static values = { url: String, frame: String, highlightSelector: String }

  connect() {
    this.selectedIndex = -1
    this.toggleClear()
    // Seed the highlight from the pre-filled value (page opened from a result ?q=…).
    this.highlightContent()

    // Re-sync option ids / aria state whenever a debounced search swaps the result
    // frame. Bound once; the frame element itself survives the inner-HTML swaps.
    this.boundSyncResults = this.syncResults.bind(this)
    const frame = document.getElementById(this.frameValue)
    if (frame) frame.addEventListener("turbo:frame-load", this.boundSyncResults)

    this.syncResults()
    // Page just opened from a keyboard Enter → put the cursor back and reselect it.
    this.resumeSelectionAfterEnter()
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
    this.clearHighlight()
    const frame = document.getElementById(this.frameValue)
    if (frame && this.boundSyncResults) {
      frame.removeEventListener("turbo:frame-load", this.boundSyncResults)
    }
  }

  search() {
    if (this.timeout) clearTimeout(this.timeout)
    this.toggleClear()
    // A new result set is coming: drop the current selection right away (the frame
    // reload below re-syncs ids and resets again once the new options arrive).
    if (this.keyboardEnabled) this.setSelectedIndex(-1)
    // Highlight immediately (no network) so the open page reacts as you type; the
    // frame reload stays debounced below.
    this.highlightContent()

    const term = this.inputTarget.value.trim()

    // Fire on clear (revert to the default widget) or once the term is long enough;
    // a single stray character is ignored to avoid pointless round-trips.
    if (term.length !== 0 && term.length < MIN_QUERY_LENGTH) return

    this.timeout = setTimeout(() => this.navigate(term), DEBOUNCE_MS)
  }

  // Explicit reset (X button): wipe the field, the result list AND the highlight,
  // but ONLY on a real click — a result click must never trigger this (it keeps the
  // list so the user can try the other hits).
  clear() {
    if (this.timeout) clearTimeout(this.timeout)
    this.inputTarget.value = ""
    const frame = document.getElementById(this.frameValue)
    if (frame) frame.innerHTML = ""
    this.clearHighlight()
    this.toggleClear()
    // Wiping innerHTML does not fire turbo:frame-load, so reset the combobox state here.
    if (this.keyboardEnabled) {
      this.selectedIndex = -1
      this.inputTarget.removeAttribute("aria-activedescendant")
      this.inputTarget.setAttribute("aria-expanded", "false")
    }
    this.inputTarget.focus()
  }

  // Show the X only while there is something to clear.
  toggleClear() {
    if (!this.hasClearTarget) return
    this.clearTarget.hidden = this.inputTarget.value.trim().length === 0
  }

  navigate(term) {
    const frame = document.getElementById(this.frameValue)
    if (!frame) return

    const url = new URL(this.urlValue, window.location.origin)
    if (term.length) {
      url.searchParams.set("q", term)
    } else {
      url.searchParams.delete("q")
    }

    frame.src = url.toString()
  }

  // --- Keyboard navigation (combobox; help + project docs only) ----------------

  // Opt-in flag: only the help/docs inputs carry role="combobox". The widget input
  // has no role, so this getter is false there and every keyboard branch is inert
  // (it also never wires the keydown action in the first place).
  get keyboardEnabled() {
    return this.hasInputTarget && this.inputTarget.getAttribute("role") === "combobox"
  }

  // Called from connect() and on every result-frame swap: hand each option a stable
  // id (so aria-activedescendant can point at it), reflect whether the list is open,
  // and invalidate any selection that belonged to the previous result set.
  syncResults() {
    if (!this.keyboardEnabled) return
    this.resultTargets.forEach((el, i) => { el.id = `${this.frameValue}-option-${i}` })
    this.inputTarget.setAttribute("aria-expanded", this.resultTargets.length ? "true" : "false")
    this.setSelectedIndex(-1)
  }

  onKeydown(event) {
    if (!this.keyboardEnabled) return
    const count = this.resultTargets.length

    switch (event.key) {
      case "ArrowDown":
        if (!count) return
        event.preventDefault()
        // From "no selection" the first arrow lands on the first card, then steps down.
        this.setSelectedIndex(this.selectedIndex < 0 ? 0 : Math.min(this.selectedIndex + 1, count - 1))
        break
      case "ArrowUp":
        if (!count || this.selectedIndex < 0) return
        event.preventDefault()
        // Up past the first card clears the selection (back to a plain text field).
        this.setSelectedIndex(this.selectedIndex === 0 ? -1 : this.selectedIndex - 1)
        break
      case "Enter":
        if (this.selectedIndex < 0) return // Enter without a selection: no-op (status quo).
        event.preventDefault()
        this.openSelected()
        break
      case "Escape":
        if (this.selectedIndex < 0) return
        // preventDefault so type=search does not also wipe the term (WebKit).
        event.preventDefault()
        this.setSelectedIndex(-1)
        break
    }
  }

  // Move the visual selection. -1 means "no selection": clears aria-activedescendant
  // and every aria-selected so the field reads as a plain input again.
  setSelectedIndex(index) {
    this.selectedIndex = index
    this.resultTargets.forEach((el, i) => {
      if (i === index) el.setAttribute("aria-selected", "true")
      else el.removeAttribute("aria-selected")
    })
    const active = index >= 0 ? this.resultTargets[index] : null
    if (active) {
      this.inputTarget.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }

  // Open the selected card exactly like a click (keeps the _top navigation + q= body
  // highlight built into the link) and flag the keyboard path for focus restore.
  openSelected() {
    const link = this.resultTargets[this.selectedIndex]
    if (!link) return
    try {
      sessionStorage.setItem(RESUME_KEY_PREFIX + this.frameValue, "1")
    } catch (_e) { /* private mode / storage disabled — navigation still works */ }
    link.click()
  }

  // After a keyboard Enter the page reloaded: if our flag is set, refocus the field and
  // reselect the just-opened card (the server marks it aria-current="page"), so arrow
  // keys keep working without a click. Absent flag (mouse click / normal load) = no-op.
  resumeSelectionAfterEnter() {
    if (!this.keyboardEnabled) return
    let flagged = false
    try {
      flagged = sessionStorage.getItem(RESUME_KEY_PREFIX + this.frameValue) === "1"
      if (flagged) sessionStorage.removeItem(RESUME_KEY_PREFIX + this.frameValue)
    } catch (_e) { return }
    if (!flagged) return

    this.inputTarget.focus()
    const openedIndex = this.resultTargets.findIndex((el) => el.getAttribute("aria-current") === "page")
    if (openedIndex >= 0) this.setSelectedIndex(openedIndex)
  }

  // --- Live body highlight (CSS Custom Highlight API) --------------------------

  highlightContent() {
    if (!this.highlightSupported) return
    CSS.highlights.delete(HIGHLIGHT_NAME)

    const container = document.querySelector(this.highlightSelectorValue)
    if (!container) return
    const term = this.inputTarget.value.trim()
    if (term.length < MIN_QUERY_LENGTH) return

    const ranges = this.matchRanges(container, term)
    if (ranges.length) CSS.highlights.set(HIGHLIGHT_NAME, new Highlight(...ranges))
  }

  clearHighlight() {
    if (this.highlightSupported) CSS.highlights.delete(HIGHLIGHT_NAME)
  }

  // Every case-insensitive occurrence of `term` inside the container, as Range
  // objects (one per hit). Matching per text node mirrors the old server highlighter:
  // a hit that spans element boundaries is intentionally not matched.
  matchRanges(container, term) {
    const ranges = []
    const needle = term.toLowerCase()
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
      const haystack = node.nodeValue.toLowerCase()
      let idx = haystack.indexOf(needle)
      while (idx !== -1) {
        const range = new Range()
        range.setStart(node, idx)
        range.setEnd(node, idx + needle.length)
        ranges.push(range)
        idx = haystack.indexOf(needle, idx + needle.length)
      }
    }
    return ranges
  }

  get highlightSupported() {
    return this.hasHighlightSelectorValue && typeof CSS !== "undefined" && !!CSS.highlights
  }
}
