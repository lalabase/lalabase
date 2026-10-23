import { Controller } from "@hotwired/stimulus"
import { FULL_PAGE_BELOW_PX } from "list_row/address"

// How often the panel re-fetches the transcript for ONE outstanding answer
// after a Turbo transplant dropped its cable subscription. See claimResync.
const RESYNC_ATTEMPTS = 3

// How far one arrow-key press moves the panel edge.
const RESIZE_STEP = 24

// How many frames the panel waits for the chip row to come back after a scope
// write before it gives up and assumes the answer was "no change" -- which is
// what a refusal looks like from here. See settleAfterScopeWrite.
const SCOPE_WRITE_FRAMES = 10

// S3a T4 — the assistant's companion lane (plan §7.7).
//
// The element this controller is attached to carries data-turbo-permanent, so
// Turbo TRANSPLANTS it into every page it renders. That single fact shapes
// everything here:
//
//   * State that must survive belongs on the NODE, not on this instance. Stimulus
//     values do exactly that (they live in data attributes on the element), which
//     is why open/width are values and not plain fields.
//   * disconnect() happens on every transplant, not just on teardown. Nothing may
//     be torn down there that the next connect() cannot rebuild — and nothing may
//     be MEASURED there either (see rememberTranscriptScroll).
//   * Turbo swaps <body> on every visit, so the content offset and the body state
//     class have to be handed to the INCOMING body in turbo:before-render.
//     Applying them after the fact would replay the 500ms transition on every
//     navigation.
export default class extends Controller {
  static targets = [
    "panel", "frame", "capsule", "capsuleInput", "capsuleMini",
    "historyFrame", "historyButton", "settingsButton", "expandButton", "collapseButton", "resizeHandle",
    "artefactFrame", "contextForm", "contextField",
    "offer", "offerSet", "offerAdd", "offerLabel", "offerTake",
    "draftReferences", "draftReferenceTemplate", "referenceStatus",
  ]
  static classes = ["open", "full"]
  static values = {
    src: String,
    open: Boolean,
    width: Number,
    minWidth: Number,
    maxWidth: Number,
    sidebarWidth: Number,
    cookieName: String,
    // The mode names come from AssistantPanelState so the cookie is written with
    // the exact strings the server parses. A literal "full" here would be a
    // second copy of a value that already has an owner.
    mode: String,
    panelMode: String,
    fullMode: String,
    // The artefact lane (S3c T3): its endpoint, and WHICH artefact is open as the
    // query string that addresses it. A value, i.e. an attribute on the permanent
    // node, so the open panel survives every transplant and every morph refresh
    // after an answer -- the failure R-M3 describes (§8.1).
    artefactSrc: String,
    artefact: String,
    // Where a write to ONE thread goes: the collection address, to which the open
    // thread's id is appended. The id cannot be baked in here -- this node is
    // permanent, the server renders it once and never learns which thread the
    // frame ended up holding (S4 T2 step 5, §7.3).
    threadUrl: String,
  }

  connect() {
    // Bound once and kept on the instance: the controller instance survives a
    // transplant together with its node, so re-registering on every connect
    // would stack duplicate listeners.
    if (!this.globalListeners) {
      this.globalListeners = true
      this.onBeforeRender = (event) => this.applyShift(event.detail.newBody)
      // A click may still be cancelled by confirmation or update only a frame.
      // Close the phone sheet only once Turbo commits to a page navigation.
      this.onVisit = () => {
        if (this.releaseIfGone()) return
        if (this.openValue && window.innerWidth < FULL_PAGE_BELOW_PX) this.close()
      }
      this.mobileQuery = window.matchMedia(`screen and (width < ${FULL_PAGE_BELOW_PX}px)`)
      this.onMobileChange = () => this.render()
      this.mobileQuery.addEventListener('change', this.onMobileChange)
      this.onToggleRequest = () => this.toggle()
      this.onAdoptRequest = (event) => this.adoptContext(event)
      this.onKeydown = (event) => this.handleKeydown(event)
      // Scroll events do not bubble, so capture:true on the document is what
      // catches scrolling of ANY container — the window as well as the inner
      // list/content lanes of the three-lane pages.
      this.onScroll = (event) => this.handleScroll(event)
      this.lastScrollTops = new WeakMap()
      // Next to its sibling above, not lazily at the point of use: a collection
      // created with ||= has to be read with ?. everywhere else, which is two
      // idioms guarding one absent field.
      // TWO sets, because they are two different refusals with two different
      // lifetimes (review of #642, B2).
      //
      //   dismissedContexts -- the user pressed the x on the strip. "Not this
      //     object." Holds for the life of the tab; a reload clears it.
      //   refusedContexts   -- the SERVER said no. Any 422 from this route: the
      //     collection is full, or the object no longer resolves. "Not now."
      //     It holds only as long as its reason
      //     does, and the reason ends the moment the collection shrinks.
      //
      // ⚠️ One set for both was a contradiction between two texts of the same
      // slice: the refusal says "Nimm einen weg, dann geht der nächste", and the
      // user who did exactly that came back to a strip that offered nothing.
      this.dismissedContexts = new Set()
      this.refusedContexts = new Set()

      // The history lane and the chat live in SEPARATE frames, so nothing tells
      // the lane that the conversation changed underneath it. This does: every
      // load of the chat frame refreshes the lane, which keeps the highlight on
      // the right row and picks up a thread that was just created.
      this.onFrameLoad = (event) => this.handleChatFrameLoad(event)
      // Delegated, not per link: the links this reacts to are rendered by the
      // server into a frame that is exchanged constantly, so nothing here may
      // depend on having seen them at connect time.
      this.onClick = (event) => this.handleClick(event)
      this.element.addEventListener("turbo:frame-load", this.onFrameLoad)
      this.element.addEventListener("click", this.onClick)
      document.addEventListener("turbo:before-render", this.onBeforeRender)
      document.addEventListener("turbo:visit", this.onVisit)
      document.addEventListener("scroll", this.onScroll, true)
      window.addEventListener("assistant-panel:toggle", this.onToggleRequest)
      window.addEventListener("assistant-panel:adopt", this.onAdoptRequest)
      // The offer's SECOND hook (step 5b). connect() alone would miss most
      // navigations that matter: the ticket detail is loaded into
      // #ticket_display_frame, so going from one ticket to the next in the list
      // is a frame load and this permanent node is never transplanted.
      //
      // On the document, therefore -- and filtered, because turbo:frame-load
      // bubbles and the panel's own frames (chat, history, artefact) fire it
      // constantly. Without the filter every answer would re-run the search.
      this.onDocumentFrameLoad = (event) => {
        if (this.releaseIfGone()) return
        if (this.element.contains(event.target)) return
        this.offerPageContext()
      }
      document.addEventListener("turbo:frame-load", this.onDocumentFrameLoad)

      // The offer's THIRD hook, and the one the review of this slice made
      // unavoidable. A frame LOAD is not how the page usually changes what it is
      // showing: #ticket_display_frame has eight writers and exactly one of them
      // (list_row_controller, which sets a src) is a load. The rest are
      // turbo_stream updates, which fire nothing, and places that assign
      // innerHTML directly (turbo_cache_controller; the kanban slide-over did
      // the same on close, until the board got the lane), which fire less than
      // nothing. Three separate defects all reduced
      // to this: the strip standing over a board with no ticket open, the strip
      // naming the ticket before, and a button that then did nothing at all.
      //
      // Scoped to <main> and NOT to document.body, deliberately: the panel is a
      // sibling of <main> at body level, and a streaming answer rewrites the
      // transcript once per token (chatpost broadcast). A body-wide observer
      // would re-run this search sixty times a second while an answer arrives,
      // for a question no answer can change.
      this.onPageMutation = () => {
        if (this.releaseIfGone()) return
        if (this.offerScheduled) return
        this.offerScheduled = true
        requestAnimationFrame(() => {
          this.offerScheduled = false
          this.offerPageContext()
        })
      }
      this.pageObserver = new MutationObserver(this.onPageMutation)

      // What a take actually did, which is the ONLY honest moment to forget that
      // one is outstanding. Not the chip's arrival: that arrives as a
      // turbo_stream replacing a div, which fires no frame load and reaches
      // nothing here -- the old comment said otherwise and was simply wrong.
      // BOTH outcomes clear it. A refusal that left it set silenced that ticket
      // for the life of the tab, and the refusal itself was invisible, so
      // nobody could have known why.
      this.onContextSubmitEnd = (event) => {
        if (!this.element.contains(event.target)) return
        // ⚠️ This fires for EVERY form in the panel, the composer included -- it
        // always did, and for the SETTLING that is right: any write can be the one
        // that redraws the chip row. What is not right for every form is touching
        // the context bookkeeping. A message sent while a context was pending must
        // not clear that slot, and it must not be read as a refusal of it.
        const ours = this.hasContextFormTarget && event.target === this.contextFormTarget
        // ⚠️ The key comes from the SUBMISSION, not from the instance slot. Between
        // takeOffer setting that slot and this event lies a whole HTTP round trip,
        // and a second take can start inside it: the slot would then name B while
        // A's refusal arrives, so A's 422 silenced B -- or A's settle nulled B's
        // still-flying slot and the loop came back. The submitted body is the only
        // thing that says which key THIS response answers.
        const key = ours ? event.detail?.formSubmission?.body?.get('key') : null
        // ⚠️ A refusal is READ OFF THE RESPONSE, not guessed from the row: Turbo
        // puts it right here. The first version inferred it from "the row came back
        // unchanged", which is wrong twice over -- a successful DUPLICATE also
        // changes nothing, and a slow successful add can outrun the frame budget
        // while an answer streams.
        //
        // ⚠️ fetchResponse separates the 422 from a NETWORK ERROR: requestErrored
        // sets success:false too, but without a response. Without this half a
        // dropped connection silences the ticket for the life of the tab, which is
        // the one outcome a refusal must not share with a hiccup.
        const refused = ours && event.detail?.success === false && Boolean(event.detail?.fetchResponse)
        // One submission of this key is no longer in flight. Released HERE, at the
        // event, but READ only in the settle -- see contextSubmissionsInFlight.
        if (ours) this.releaseContextSubmission(key)
        this.settleAfterScopeWrite({ ours: ours, key: key, refused: refused })
      }
      this.element.addEventListener("turbo:submit-end", this.onContextSubmitEnd)
      this.onPendingMeetingIntentSubmit = (event) => this.guardPendingMeetingIntentSubmit(event)
      this.element.addEventListener("submit", this.onPendingMeetingIntentSubmit, true)
      window.addEventListener("keydown", this.onKeydown)
    }

    // Reparenting resets scrollTop, so restore what the last scroll event saw.
    this.restoreTranscriptScroll()
    this.render()

    // Turbo renders a CACHED PREVIEW before the fresh page on every visit to an
    // address it has seen, so the node is transplanted twice and connect() runs
    // twice. Everything below this line either costs a request or spends a
    // budget, and doing it against a preview is pure waste: the fetch would be
    // cancelled moments later by the real render, and the resync allowance
    // (three per outstanding answer) was gone after a single cached navigation.
    // Turbo marks the preview on <html>.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    // honourRequestedChat FIRST: it knows the exact address (…?chat_id=…), and
    // loadFrame only arms a src if none is set yet. The other order fetched the
    // default transcript and then immediately replaced the request -- the client
    // cancels the first fetch, but the server has already rendered a conversation
    // nobody will see.
    this.honourRequestedChat()
    this.honourRequestedMode()
    this.honourRequestedArtefact()
    this.observePageContent()
    this.offerPageContext()
    if (this.openValue) this.loadFrame()
    // A hard reload can land straight in the full view (the cookie carries the
    // mode), and then the lane has to arm itself without anybody clicking.
    if (this.isFull()) this.armHistoryLane()
    this.resyncIfAwaitingAnswer()
  }

  disconnect() {
    // Deliberately empty. A transplant fires disconnect() and connect() on the
    // SAME node with the SAME controller instance; tearing the global listeners
    // down here would remove them for the rest of the session, and a real page
    // unload takes the whole JS context anyway.
  }

  // --- entry points ---------------------------------------------------------

  handleKeydown(event) {
    // Cmd/Ctrl+J, the sibling of the search overlay's Cmd+K.
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "j") return
    event.preventDefault()
    this.toggle()
  }

  // Below the panel's breakpoint there is nothing to open: the whole node is
  // `hidden lg:block`, so opening would flip an invisible element and write an
  // open state into the cookie that surprises the next wide window. Asked of the
  // DOM rather than of window.innerWidth on purpose -- the breakpoint lives in
  // CSS, and a second copy of it here is exactly what an earlier round had to
  // take out again.
  //
  // A PREDICATE and not a line inside toggle(), because it now has more than one
  // caller: S4 T2 step 5 added the button in a ticket header, which sits OUTSIDE
  // this node and is therefore clickable exactly where the panel is not. Step 5b
  // brings a third. A rule that every entry point has to remember on its own is
  // a rule that one of them will forget -- this one already did, and the cost was
  // a reference written to the database with nothing on screen to show for it.
  canOpen() {
    return this.element.offsetParent !== null
  }

  toggle() {
    if (!this.canOpen()) return

    if (this.openValue) this.close()
    else this.open()
  }

  open() {
    // Remember where the focus came from, so closing can give it back. Every
    // other layer in this app (search overlay, both drawers) does this; the panel
    // dropped the focus on the body, which strands anyone navigating by keyboard.
    this.previouslyFocused = document.activeElement
    this.openValue = true
    this.persist()
    this.render()
    this.loadFrame()
    // After render(): the panel was display:none a moment ago, and a hidden
    // container cannot be scrolled. On the very first open the frame is still
    // empty and this is a no-op; the frame-load below takes over then.
    this.showTranscriptEnd()
    this.focusComposer()
  }

  close() {
    this.openValue = false
    // Back to the companion mode on the way out. The panel is the normal state
    // (L11: a companion lane), the full view is a deliberate excursion — and a
    // Cmd+J that unexpectedly fills the screen is a bad way to start one. The
    // width is remembered, the excursion is not.
    this.modeValue = this.panelModeValue
    this.persist()
    this.render()
    this.restoreFocus()
  }

  // Back to whatever opened the panel, or to the capsule as the standing
  // invitation. Never to the body.
  restoreFocus() {
    const target = this.previouslyFocused
    this.previouslyFocused = null
    if (target && target.isConnected && target.offsetParent !== null) return target.focus()

    const trigger = document.querySelector("#assistant-panel-trigger")
    if (trigger) trigger.focus()
    else if (this.hasCapsuleInputTarget) this.capsuleInputTarget.focus()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // Its Escape is bound to the panel, so only a key pressed inside it counts.
  ownsEscape() {
    return this.openValue && this.hasPanelTarget && this.panelTarget.contains(document.activeElement)
  }

  // Escape closes, like every other layer here. Bound to the panel, not to the
  // document: a modal opened on top of the page must keep its own Escape.
  closeOnEscape(event) {
    if (event.key !== "Escape") return
    event.preventDefault()
    this.close()
  }

  // Enter in the capsule: unfold the panel in place and hand the text over to
  // the composer instead of making the user type it again.
  // Enter in the capsule ASKS the question, it does not park it (26.08.2026). The
  // field is at the bottom edge of the screen and looks like every other chat
  // input; filling the composer and waiting for a second trigger read as a
  // swallowed question.
  //
  // TWO deliberate exceptions:
  //   * a draft already standing in the composer is appended to, not fired --
  //     firing would post somebody's half-written sentence along with it.
  //     Whitespace alone is not a draft: hadDraft decides BOTH the append and
  //     the send, so a stray space cannot smuggle a blank first line into the
  //     message while still counting as nothing worth protecting,
  //   * the capsule is cleared only once a composer actually took the text. With
  //     no usable AI credential the panel serves the reason instead of a field,
  //     and clearing up front would drop the question into nothing.
  submitCapsule(event) {
    event.preventDefault()
    const input = this.capsuleInputTarget
    const text = input.value.trim()
    this.open()
    if (!text) {
      input.value = ""
      return
    }

    this.whenComposerReady((field) => {
      const hadDraft = field.value.trim() !== ""
      input.value = ""
      field.value = hadDraft ? `${field.value}\n${text}` : text
      field.focus()
      // The composer autogrows on input; without the event the field stays one
      // line tall around a two-line question.
      field.dispatchEvent(new Event("input", { bubbles: true }))
      if (!hadDraft) field.form?.requestSubmit()
    })
  }

  openFromMini() {
    this.expandCapsule()
    this.capsuleInputTarget.focus()
  }

  // --- taking over the page's object (S4 T2 step 5, plan §7.3) ---------------

  // A button in a ticket header said "this page is about #112". Everything the
  // page could not know is decided here and on the server: WHICH thread it lands
  // on (this node knows, the page does not), and whether that object may stand
  // there at all (Tools::Scope#resolve_reference, the same owner the chip reads
  // through).
  //
  // Never silent: opening the panel is part of the act, so the chip that appears
  // is on screen the moment it is set. §7.3 forbids a context that is taken over
  // without the user seeing it, and this is the explicit half of that rule -- the
  // button IS the user asking.
  adoptContext(event) {
    const referenceKey = event.detail?.referenceKey
    const intent = event.detail?.intent
    if (!referenceKey || !this.hasContextFormTarget) return
    // Same door as Cmd+J and the sidebar row: no lane on this viewport, no
    // reference. Setting one here would store it with nothing to show for it,
    // which is the silent takeover §7.3 forbids -- and it would leave the panel
    // marked open in the cookie for the next wide window.
    if (!this.canOpen()) return

    this.open()
    // Waiting for the COMPOSER, not for any anchor: the reference chip renders
    // only next to it (ChatContainerComponent), so where there is no composer
    // there is nothing to set and nowhere to show it. It is also the wait that
    // already exists, and the one the capsule uses for the same reason -- the
    // frame may not have been fetched at all before this click.
    this.whenComposerReady(() => {
      if (this.standingKeySet().has(referenceKey)) {
        // The chip can be back before the settle of the write that brought it has
        // run (it watches the row for up to SCOPE_WRITE_FRAMES). An explicit intent
        // fulfilled right here replaces the one still waiting for that settle,
        // which would otherwise switch the mode back a few frames later.
        if (intent && this.pendingMeetingIntents?.delete(referenceKey) && !this.pendingMeetingIntents.size) {
          this.showComposerStatus("")
        }
        this.fulfilMeetingIntent(intent, referenceKey)
        return
      }

      const thread = this.openThreadId()
      if (!thread) {
        const context = this.pageContexts().find(candidate => candidate.key === referenceKey)
        if (context) {
          this.addDraftReference(context)
          if (this.standingKeySet().has(referenceKey)) this.fulfilMeetingIntent(intent, referenceKey)
        }
        return
      }

      // ⚠️ The SAME key is already on its way (or its answer is in and its settle
      // is still watching the row). A second requestSubmit on this top-level form
      // is not a second request next to the first: Turbo's Navigator.submitForm
      // stop()s the running submission, so a double click -- or "Analyse" and
      // then "Aufgaben" on the same meeting within one round trip -- aborted the
      // write that carried the first intent, and the chip arrived while the mode
      // never opened. The flying request already writes this key; the only thing
      // the click adds is WHICH mode to open, and the settle reads that from the
      // map when it runs, so the newest intent wins without a resubmit. A click
      // without an intent (the offer strip) asks for nothing new and must not
      // erase the one that is waiting.
      if (this.pendingContext === referenceKey) {
        if (intent) this.pendingMeetingIntents ||= new Map()
        if (intent) this.pendingMeetingIntents.set(referenceKey, intent)
        return
      }

      // POST to the thread's reference COLLECTION since S1 (§7.1). The key is
      // the whole body -- one value, the same one the chip publishes and the
      // DELETE address carries.
      this.contextFormTarget.action = `${this.threadUrlValue}/${encodeURIComponent(thread)}/references`
      this.contextFieldTarget.value = referenceKey
      // Armed HERE, immediately before the submit, so it cannot outlive a path
      // that never sends anything (see takeOffer). Cleared by that request's own
      // settle, matched on the key it submitted.
      this.pendingContext = referenceKey
      if (intent) this.pendingMeetingIntents ||= new Map()
      if (intent) this.pendingMeetingIntents.set(referenceKey, intent)
      // Counted BEFORE the submit, never at turbo:submit-start: the submit below
      // is what aborts an older submission, and that one's submit-end must
      // already see this one as outstanding (see contextSubmissionsInFlight).
      this.contextSubmissionsInFlight ||= new Map()
      this.contextSubmissionsInFlight.set(referenceKey, (this.contextSubmissionsInFlight.get(referenceKey) || 0) + 1)
      this.contextFormTarget.requestSubmit()
    })
  }

  // How many context-form submissions for each key were REQUESTED and have not
  // yet reached turbo:submit-end. It exists for exactly one question the settle
  // has to answer: "is my submission the last word on this key, or has a newer
  // one taken over?" Only the last word may drop the pending meeting intent (or
  // clear pendingContext) -- an older one deleting it leaves the newer response
  // to render the chip into a composer whose mode then never opens.
  //
  // ⚠️ Why a count and not the two obvious tells (read in the Turbo 8.0.13 source
  // turbo-rails ships, FormSubmission/FetchRequest/Navigator -- not assumed):
  //
  //   * Ignoring submit-ends without a response. submit-end is dispatched from
  //     FetchRequest's `finally` as { formSubmission, ...result }, and `result`
  //     is only set by a response (success + fetchResponse) or by requestErrored
  //     (success:false + error). An AbortError sets neither, so an aborted
  //     submission really does arrive as { formSubmission } alone. But being
  //     aborted does not mean being superseded: Navigator.startVisit calls the
  //     same stop(), so clicking any link -- or submitting any other top-level
  //     form -- aborts the scope write with NO successor. Ignoring that event
  //     leaks the entry, and guardPendingMeetingIntentSubmit then holds the
  //     composer until a reload.
  //   * Keying on the FormSubmission from turbo:submit-start. The aborted
  //     submission's submit-end comes FIRST: stop() aborts its fetch inside the
  //     successor's own submit handler, so the old rejection is queued before
  //     the successor even reaches its `await` on turbo:before-fetch-request,
  //     which stands between it and its submit-start. At the moment the old one
  //     ends, nothing yet says a new one exists.
  //
  // The count is incremented synchronously in adoptContext, before the
  // requestSubmit that causes the abort, and decremented at submit-end. It is
  // READ in the settle, frames later: that also covers a newer submission
  // requested after the old answer arrived but before its settle ran.
  releaseContextSubmission(key) {
    const remaining = (this.contextSubmissionsInFlight?.get(key) || 0) - 1
    if (remaining > 0) this.contextSubmissionsInFlight.set(key, remaining)
    else this.contextSubmissionsInFlight?.delete(key)
  }

  contextSubmissionSuperseded(key) {
    return (this.contextSubmissionsInFlight?.get(key) || 0) > 0
  }

  // A meeting entry may ask for more than adopting a reference. Do that only
  // after the reference is visibly part of the current draft/thread. A refused
  // scope write therefore cannot arm an action for an unrelated meeting.
  fulfilMeetingIntent(intent, referenceKey) {
    if (!intent || !referenceKey.startsWith("Meeting:")) return

    const form = this.composerField()?.form
    if (!form) return
    const meetingId = referenceKey.slice("Meeting:".length)
    if (intent === "analysis") {
      form.dispatchEvent(new CustomEvent("assistant:analysis-request", { detail: { meetingId } }))
    } else if (intent === "ticket-suggestions") {
      form.dispatchEvent(new CustomEvent("assistant:suggestion-request", { detail: { meetingId } }))
    }
    this.focusComposer()
  }

  // Keep the current draft and mode visible while the server decides whether a
  // newly requested meeting may join this thread, but do not let that old mode
  // submit against its previous meeting in the meantime.
  //
  // ⚠️ The COMPOSER'S form, and nothing else. This listener captures `submit`
  // for the whole panel, and its first version blocked every form but the
  // context form: accepting or dismissing a suggestion card, retrying a run,
  // removing a chip, deleting a thread -- all swallowed while a meeting
  // reference was on its way, none of them with a word of explanation. None of
  // them can submit against the previous meeting's mode; only the message can.
  // (The context form needs no exemption any more: it is not the composer.)
  //
  // ⚠️ And never silent. The status used to live in DraftReferencesComponent,
  // which renders only for a NEW chat -- and an open thread is precisely where a
  // pending intent exists (adoptContext only POSTs when there is a thread), so
  // the block said nothing in the one place it happens. Its text was also the
  // wrong one: reference_busy says the current MESSAGE will finish first, which
  // is the draftSubmitting() state, not this. The composer renders its own
  // status in both modes (ComposerComponent, `data-composer-status`), carrying
  // the pending_reference label with it.
  guardPendingMeetingIntentSubmit(event) {
    if (!this.pendingMeetingIntents?.size) return
    const form = this.composerField()?.form
    if (!form || event.target !== form) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.showComposerStatus(this.composerStatus()?.dataset.pendingReferenceLabel)
  }

  // Asked of the composer's FORM, not of the panel: a marker in this node is not
  // unique (see showHistory), and the message this status explains belongs to
  // exactly the form that was refused.
  composerStatus() {
    return this.composerField()?.form?.querySelector("[data-composer-status]") || null
  }

  // Revealed and filled in the same task, like showDraftReferenceStatus: the
  // element is role="alert", which is announced when it appears with content.
  showComposerStatus(message) {
    const status = this.composerStatus()
    if (!status) return
    status.textContent = message || ""
    status.hidden = !message
  }

  // These targets arrive after a Turbo Stream as well as after a frame load.
  // The permanent controller keeps no second draft copy: the form is its state.
  offerTargetConnected() {
    requestAnimationFrame(() => this.offerPageContext())
  }

  guardDraftSubmit(event) {
    if (!this.draftSubmitting()) return
    event.preventDefault()
    event.stopImmediatePropagation()
  }

  draftSubmissionChanged(event) {
    if (!this.hasDraftReferencesTarget || !event.target.contains(this.draftReferencesTarget)) return

    this.draftSubmissions ||= new WeakMap()
    const submitting = event.type === 'turbo:submit-start'
    if (submitting) {
      this.draftSubmissions.set(event.target, event.detail?.formSubmission)
    } else {
      if (this.draftSubmissions.get(event.target) !== event.detail?.formSubmission) return
      // submit-end can precede reading/rendering a Turbo Stream body. Its new
      // form arrives unlocked; the submitted form must stay fixed until then.
      // Network failures/non-stream errors leave this form standing, so unlock it.
      if (event.detail?.fetchResponse?.contentType?.includes('text/vnd.turbo-stream.html')) return
      this.draftSubmissions.delete(event.target)
    }
    this.draftReferencesTarget.dataset.submitting = String(submitting)
    this.draftReferencesTarget.querySelectorAll('button').forEach((button) => { button.disabled = submitting })
    this.offerPageContext()
  }

  draftSubmitting() {
    return this.hasDraftReferencesTarget && this.draftReferencesTarget.dataset.submitting === 'true'
  }

  addDraftReference(context) {
    if (this.draftSubmitting()) {
      this.showDraftReferenceStatus(this.draftReferencesTarget.dataset.referenceBusyLabel)
      return
    }
    if (!this.hasDraftReferencesTarget || this.standingKeySet().has(context.key)) return
    if (this.standingKeySet().size >= Number(this.draftReferencesTarget.dataset.referenceLimit)) {
      this.showDraftReferenceStatus(this.draftReferencesTarget.dataset.referenceLimitLabel)
      return
    }

    this.showDraftReferenceStatus("")
    const pill = this.draftReferenceTemplateTarget.content.firstElementChild.cloneNode(true)
    const label = pill.querySelector('[data-draft-label]')
    label.textContent = context.label
    label.title = context.label
    pill.querySelector('input').value = context.key
    pill.querySelector('button').setAttribute('aria-label',
      this.draftReferencesTarget.dataset.removeLabel.replace('__TITLE__', context.label))
    this.draftReferencesTarget.append(pill)
    this.syncDraftReferences()
    this.composerField()?.focus()
  }

  removeDraftReference(event) {
    if (this.draftSubmitting()) return
    event.currentTarget.closest('[data-draft-reference]').remove()
    this.showDraftReferenceStatus("")
    this.syncDraftReferences()
    this.composerField()?.focus()
  }

  syncDraftReferences() {
    this.draftReferencesTarget.dataset.referenceKeys = Array.from(
      this.draftReferencesTarget.querySelectorAll('input'), (input) => input.value
    ).join(' ')
    this.offerPageContext()
  }

  showDraftReferenceStatus(message) {
    if (!this.hasReferenceStatusTarget) return
    this.referenceStatusTarget.textContent = message || ""
    this.referenceStatusTarget.hidden = !message
  }

  // --- the offer when navigating (S4 T2 step 5b, plan §7.3) -------------------

  // "The panel MAY offer the new page context as a takeable chip, and never
  // takes it over silently." This is the offer. It reads the page, decides
  // whether there is anything worth offering, and shows or hides the strip in
  // the shell. It writes NOTHING -- taking it runs adoptContext, i.e. the exact
  // path the button in the object's header already uses, so "may this object
  // stand on this thread?" keeps its single owner
  // (Tools::Scope#resolve_reference) and there is no second check anywhere near
  // here.
  //
  // Six reasons to stay away, all of them silent by design (an offer that
  // explains why it is not there would be the intrusion the plan rules out):
  offerPageContext() {
    if (!this.hasOfferTarget) return
    if (this.draftSubmitting()) return this.hideOffer()

    // 0. the transcript has never loaded, so the chip that says whether a
    //    reference stands is not in the DOM YET -- and "no chip" would read as
    //    "no reference". On a hard reload with the panel open that flashed
    //    "Bezug setzen" over a page whose reference was already set. The frame's
    //    own load calls this again a moment later, so nothing is lost by waiting.
    //
    if (!this.chatFrameSeen) return this.hideOffer()

    // The page may name more than one object: the ticket and, beside it, its
    // meeting (doc/ticket_meeting_panel_plan.md, S3). They are offered one after
    // the other, in page order, through the one strip: taking or refusing the
    // first brings up the next. Every guard below asks about one of them.
    const contexts = this.pageContexts()
    // 1. the page names no object -- most pages do not.
    if (!contexts.length) return this.hideOffer()
    // 2. this device has no companion lane, so there is nowhere to show a
    //    reference and nothing to take it into (same door as toggle/adoptContext).
    if (!this.canOpen()) return this.hideOffer()
    const standing = this.standingReferenceKeys()
    const standingKeys = this.standingKeySet()
    // 4. (for the slot) a context that has arrived in the collection is no longer
    //    on its way.
    if (this.pendingContext && standingKeys.has(this.pendingContext)) this.pendingContext = null
    // 4b. A context of this page on its WAY into the collection holds the strip
    //     back for ALL of them. Between the click and the stream that brings the
    //     chip back, the thread has no visible reference yet, and any unrelated
    //     frame load in that window re-raises the offer for something that is
    //     already being set (a ticket page brings its own: the lazy timeline
    //     frame reaches the document listener; found as a flaky assertion, kept
    //     as a rule). And offering the NEXT one meanwhile would invite a second
    //     requestSubmit on the same form, which stops the first (adoptContext).
    //     Its settle asks again and the next one comes up then.
    if (contexts.some(candidate => candidate.key === this.pendingContext)) return this.hideOffer()
    // 3. refused for this object -- by hand (dismissOffer, permanent for the tab)
    //    or by the server (any 422 from the reference route: the limit, or an
    //    object that no longer resolves). Cleared as soon as the standing set
    //    shrinks, so a refusal outlives only its own reason.
    // 4. the reference collection already CONTAINS this very object -- nothing
    //    to take. Membership, not equality: with more than one entry (S2) the
    //    question is whether it is in there.
    const context = contexts.find(candidate =>
      !this.dismissedContexts.has(candidate.key) &&
      !this.refusedContexts.has(candidate.key) &&
      !standingKeys.has(candidate.key))
    if (!context) return this.hideOffer()
    // A new conversation holds references in its form until the first message.
    // History/settings have neither a thread nor a draft, and offer nothing.
    if (!this.openThreadId() && !this.hasDraftReferencesTarget) return this.hideOffer()
    if (this.hasDraftReferencesTarget &&
        this.standingKeySet().size >= Number(this.draftReferencesTarget.dataset.referenceLimit)) return this.hideOffer()

    this.showOffer(context, standing)
  }

  // The rendering half, kept apart from the deciding half above: asking "is there
  // anything to offer?" should not also be the thing that writes five attributes,
  // and the reset of pendingContext buried in guard 4 was the only state change
  // hiding inside what otherwise reads as a predicate.
  showOffer(context, standing) {
    // Already saying exactly this. Bailing here is not only cheaper, it is what
    // keeps role="status" honest: every assignment to textContent replaces the
    // text node and counts as a live-region change, and this runs on every frame
    // load and every page mutation, so without it a ticket page's own lazy
    // frames made the strip announce itself again for no reason at all.
    //
    // ⚠️ The STANDING reference is part of "exactly this", not just the ticket.
    // Setting a reference while staying on the same page turns the very same
    // offer from a setting into a switch, and comparing the ticket alone would
    // leave the strip saying "Bezug setzen" next to a thread that already has one.
    const unchanged = this.offerTarget.dataset.contextId === context.key &&
      this.offerTarget.dataset.contextStanding === (standing || "") &&
      !this.offerTarget.classList.contains("hidden")
    if (unchanged) return

    // Revealed FIRST, then filled. A live region that is display:none is not in
    // the accessibility tree, so content written before the reveal is content no
    // screen reader ever saw change -- the strip would appear in silence, which
    // is exactly what role="status" is here to prevent. Filling it a frame later
    // is a mutation of a region that is already there, which is announced.
    this.offerTarget.classList.remove("hidden")
    this.offerTarget.dataset.contextId = context.key
    this.offerTarget.dataset.contextStanding = standing || ""

    // ⚠️ Same task, NOT a frame later. Deferring the text was the obvious way to
    // let the live region observe its own change, and it bought a worse defect:
    // the strip became visible for one frame still carrying the PREVIOUS
    // ticket's name, and anything reading the strip in between saw the two
    // disagree. The accessibility tree is recomputed at the end of this task
    // either way, so revealing before writing is all the ordering that is
    // needed -- what the deferral was really compensating for was hideOffer
    // leaving the old label standing, and that is fixed where it belongs.
    this.offerLabelTarget.textContent = context.label
    this.offerLabelTarget.title = context.label
    // A standing collection makes this an ADDITION, not a first setting. Two
    // sentences in the markup, one of them hidden -- never one rewritten here.
    // (It said "switch" until S2, when the limit was one and a second reference
    // displaced the first.)
    this.offerSetTarget.classList.toggle("hidden", Boolean(standing))
    this.offerAddTarget.classList.toggle("hidden", !standing)
    // ...and the button POINTS at whichever of them is showing, plus the title.
    // Without this the screen reader hears "Uebernehmen" and nothing else: the
    // sentences are siblings, and a sibling describes nothing. Only the
    // reference is swapped here, never the text -- that stays where the server
    // put it.
    this.offerTakeTarget.setAttribute(
      "aria-describedby",
      `${standing ? this.offerAddTarget.id : this.offerSetTarget.id} ${this.offerLabelTarget.id}`
    )
  }

  takeOffer() {
    // The page is asked AGAIN rather than trusting what the strip remembers. A
    // page can drop its object without making a sound (innerHTML in
    // turbo_cache_controller; the kanban slide-over did too, until the board
    // got the lane), and the observer in
    // connect() closes most of that, but not the frame between a mutation and
    // the next repaint. Comparing what the page says NOW against what was
    // offered costs one querySelectorAll and is the last word.
    const offered = this.offerTarget.dataset.contextId
    const referenceKey = this.pageContexts().some(context => context.key === offered) ? offered : null

    // ⚠️ NOT hidden before the guard. The first version hid unconditionally, so a
    // click on a stale strip looked EXACTLY like a click that worked: the strip
    // vanished, nothing was written, nothing was said, and the focus was left on
    // the body. A failure that is indistinguishable from success is the one
    // outcome an unprompted offer may not have.
    if (!referenceKey) return this.offerPageContext()

    // Hidden only once there is something to hide it FOR: the strip has done its
    // job the moment somebody accepts, and leaving it up until the stream comes
    // back shows an offer for something that is already being set.
    this.hideOffer()
    // ⚠️ pendingContext is armed where the request is actually SENT (see
    // adoptContext), not here. adoptContext has three ways out before it submits
    // -- no form, no lane, no thread -- and setting the slot in front of them left
    // it standing with no response ever coming, which made guard 4b swallow that
    // ticket's offer for the life of the tab.
    this.adoptContext({ detail: { referenceKey } })
  }

  dismissOffer() {
    const referenceKey = this.offerTarget.dataset.contextId
    // Taken BEFORE the strip goes away: hiding the element that holds the focus
    // drops it on the body, and this file already learned that lesson twice
    // (see open() and restoreFocus). takeOffer escapes it only by accident,
    // because adoptContext opens the panel and focuses the composer.
    const hadFocus = this.offerTarget.contains(document.activeElement)
    this.hideOffer()
    if (hadFocus) this.focusComposer()
    if (!referenceKey) return

    // On the INSTANCE, deliberately, and nowhere else. The instance survives a
    // transplant together with its node, so the refusal holds for as long as the
    // tab lives; a reload clears it. A cookie or a column would make it outlive
    // the situation it belongs to, and then somebody wonders for weeks why a
    // ticket never offers itself.
    //
    // ⚠️ dismissedContexts, not refusedContexts: this one is the USER saying "not
    // this object", and it outlives a shrinking collection. The server's refusal
    // says "not now" and is cleared as soon as room appears.
    this.dismissedContexts.add(referenceKey)
  }

  hideOffer() {
    if (!this.hasOfferTarget) return

    this.offerTarget.classList.add("hidden")
    delete this.offerTarget.dataset.contextId
    delete this.offerTarget.dataset.contextStanding
    // Emptied, not left standing. A label that survives the hiding makes the next
    // offer for the SAME ticket a write of identical text, i.e. no mutation and
    // no announcement -- and it leaves the previous ticket's name sitting in the
    // accessibility tree of a strip that is no longer offering it.
    this.offerLabelTarget.textContent = ""
    this.offerLabelTarget.removeAttribute("title")
  }

  // What the page says it is showing: every object it names, in page order and
  // each once (the ticket's two roots both name it). Searched rather than
  // received: this node is permanent, so nothing ever renders a message to it.
  //
  // The panel's own subtree is excluded on purpose -- an answer may well quote a
  // ticket, and a citation must never become an offer to re-point the thread.
  //
  // So is a marker inside a CLOSED lane. The ✕ of a lane (layout-toggle
  // #closeContent) hides the content column by class and leaves its markup
  // standing, so the note just closed would otherwise stay on offer for as
  // long as nothing else replaced the frame. The class is the lane's own state
  // (.layout.hide-content, the one flag updateLayout writes), and
  // observePageContent watches it so the offer follows the ✕ the same way it
  // follows a frame load. The same for a CLOSED third lane (.layout.hide-panel,
  // the meeting beside a ticket): closing empties that lane too, but the class
  // flips first, and the class is what the reader sees.
  pageContexts() {
    const contexts = []
    const keys = new Set()
    for (const marker of document.querySelectorAll("[data-assistant-context]")) {
      if (this.element.contains(marker)) continue
      if (marker.closest(".layout.hide-content")) continue
      if (marker.closest(".layout.hide-panel > .column.panel")) continue

      const id = marker.dataset.assistantContext
      const type = marker.dataset.assistantContextType
      const label = marker.dataset.assistantContextLabel
      if (!id || !type || !label) continue
      // The composite key of §7.1, composed HERE and nowhere else on this side:
      // the page names a type and an id, the collection is addressed by the pair.
      const key = `${type}:${id}`
      if (keys.has(key)) continue

      keys.add(key)
      contexts.push({ key, label })
    }
    return contexts
  }

  // Which objects the thread points at right now, read off the chip the server
  // rendered, as the raw space-separated key list. Same channel as openThreadId,
  // and for the same reason: the server never gets to tell this node anything.
  //
  // The whole STRING is what settleAfterScopeWrite compares -- a write that
  // changes the collection changes this attribute, and a refusal leaves it
  // identical, which is exactly the difference that method is watching for.
  standingReferenceKeys() {
    const chip = this.element.querySelector("[data-reference-keys]")
    return chip ? chip.dataset.referenceKeys : null
  }

  // The same thing as a set, for the one question that is about membership
  // rather than about change ("does the collection already contain this?").
  standingKeySet() {
    return new Set((this.standingReferenceKeys() || "").split(" ").filter(Boolean))
  }

  // WATCHING for the outcome of a scope write rather than guessing at when it
  // lands. submit-end fires once Turbo has the response, but the stream that
  // rewrites the chip row renders after that and announces itself with nothing at
  // all -- it replaces a div, and a div replacement is not a frame load.
  //
  // Since S2 it also carries the context bookkeeping, but only for its OWN form
  // (`ours`): this method runs for the composer too. Whether the write was
  // REFUSED it no longer guesses -- Turbo hands that over in detail.success.
  //
  // Both mistakes here are real and both were made. Clearing on submit-end alone
  // re-offered the very ticket that had just been set, because the row still
  // said "no reference" at that instant and no later run was scheduled to correct
  // it: not a flicker, a standing offer to set what was already set. Never
  // clearing at all is the other one -- the flag then outlived the write, and
  // removing the chip afterwards silenced that ticket for the life of the tab.
  //
  // So: watch the row until it CHANGES, then clear and ask again. The frame
  // budget is the backstop for the case where the row comes back identical,
  // which is exactly what a refusal looks like.
  settleAfterScopeWrite({ ours = false, key = null, refused = false } = {}) {
    const before = this.standingReferenceKeys()
    const beforeSize = this.standingKeySet().size
    let frames = 0

    const settle = () => {
      if (this.standingReferenceKeys() === before && frames++ < SCOPE_WRITE_FRAMES) {
        requestAnimationFrame(settle)
        return
      }

      // ⚠️ The limit's refusals end when the limit does. The collection got
      // smaller, so "not now" stopped being true for every one of them -- and the
      // message the server sent says exactly that ("Nimm einen weg, dann geht der
      // nächste"). Not tied to `ours`: the entry usually goes through the chip's
      // own cross, which is a different form.
      if (this.standingKeySet().size < beforeSize) this.refusedContexts.clear()

      if (ours) {
        // ⚠️ A newer submission of the SAME key has taken over (see
        // contextSubmissionsInFlight): this one was aborted by it, or answered
        // before it. The slot and the intent belong to the newer one now and are
        // settled by ITS settle; everything else below still applies.
        const superseded = this.contextSubmissionSuperseded(key)
        // ⚠️ Only MY OWN key leaves the slot. A second take that started while this
        // response was in flight owns it now, and clearing it here would drop the
        // guard that keeps its offer from being raised again.
        if (!superseded && this.pendingContext === key) this.pendingContext = null
        // ⚠️ A REFUSED context is silenced for this tab (plan §8.3). Without it the
        // limit builds a loop that did not exist before S2: click, 422 "at most
        // ten", the row comes back identical, the collection still does not
        // contain the key, so the strip offers it again -- and the only way out
        // is to remove a reference or reload. Rare with a limit of one, routine
        // with ten.
        //
        // A DUPLICATE needs no guard here any more: it answers 200, so `refused`
        // is false and the key keeps its right to offer itself again.
        if (refused && key) this.refusedContexts.add(key)
        if (!superseded) {
          // Read HERE, not at submit-end: a click on the same key while this one
          // was flying updated the intent instead of resubmitting (adoptContext),
          // so the newest mode is whatever the map says now.
          const intent = this.pendingMeetingIntents?.get(key)
          // With the last pending intent goes the reason the composer was
          // refused, so its explanation must not outlive it.
          if (this.pendingMeetingIntents?.delete(key) && !this.pendingMeetingIntents.size) this.showComposerStatus("")
          if (!refused && key && this.standingKeySet().has(key)) this.fulfilMeetingIntent(intent, key)
        }
      }
      this.offerPageContext()
    }
    requestAnimationFrame(settle)
  }

  // <main> is a fresh element after every Turbo visit, so the observer has to be
  // re-aimed on every connect. Idempotent: the same element is never observed
  // twice, and a layout without a <main> simply leaves the third hook unarmed
  // rather than falling back to <body>, where a streaming answer lives.
  observePageContent() {
    if (!this.pageObserver) return

    const main = document.querySelector(".mobile-app-screen > main, body > main")
    if (!main || this.observedMain === main) return

    this.pageObserver.disconnect()
    this.pageObserver.observe(main, { childList: true, subtree: true })
    // The lane's open/closed state is a CLASS on the grid, not a node coming
    // or going (layout-toggle#updateLayout), so the child-list watch above
    // never sees the ✕. Watched on that one element and that one attribute
    // rather than every attribute under <main>: the same rAF-coalesced handler,
    // one more target. A page without a grid has nothing to watch here.
    const layout = main.querySelector(".layout")
    if (layout) this.pageObserver.observe(layout, { attributes: true, attributeFilter: ["class"] })
    this.observedMain = main
  }

  // The permanent node survives to the next page only if that page renders the
  // panel at all, and assistant_available? says no wherever there is no current
  // organisation: the org switcher, the account pages, admin, /hilfe. Turbo then
  // drops this node and the instance dies with it -- but the listeners on
  // document and window do NOT die, and each of them keeps the dead instance and
  // its whole detached subtree alive. One more set per round trip, forever, and
  // in between they run against a panel nobody can see.
  //
  // disconnect() cannot do this: a transplant fires it too, on a node that is
  // coming straight back. So the listeners retire themselves instead, and only
  // after asking a SECOND time in a later task -- a transplant has the node out
  // of the document for a moment, and retiring in that moment would tear down a
  // panel that is perfectly alive.
  releaseIfGone() {
    if (this.element.isConnected) return false
    if (this.releaseScheduled) return true

    this.releaseScheduled = true
    setTimeout(() => {
      this.releaseScheduled = false
      if (this.element.isConnected) return

      document.removeEventListener("turbo:frame-load", this.onDocumentFrameLoad)
      document.removeEventListener("turbo:before-render", this.onBeforeRender)
      document.removeEventListener("turbo:visit", this.onVisit)
      document.removeEventListener("scroll", this.onScroll, true)
      window.removeEventListener("assistant-panel:toggle", this.onToggleRequest)
      window.removeEventListener("assistant-panel:adopt", this.onAdoptRequest)
      window.removeEventListener("keydown", this.onKeydown)
      this.mobileQuery.removeEventListener("change", this.onMobileChange)
      this.pageObserver.disconnect()
      this.observedMain = null
    }, 0)
    return true
  }

  // --- rendering ------------------------------------------------------------

  render() {
    const full = this.isFull()
    const mobileModal = window.innerWidth < FULL_PAGE_BELOW_PX && this.openValue
    const screen = document.querySelector('.mobile-app-screen')
    if (screen) screen.inert = mobileModal
    this.panelTarget.setAttribute('role', mobileModal ? 'dialog' : 'complementary')
    if (mobileModal) this.panelTarget.setAttribute('aria-modal', 'true')
    else this.panelTarget.removeAttribute('aria-modal')

    this.panelTarget.classList.toggle("hidden", !this.openValue)
    this.capsuleTarget.classList.toggle("hidden", this.openValue)
    this.panelTarget.classList.toggle("assistant-panel--full", full)
    // Both classes together open the third track (components/assistant_panel.css):
    // leaving the full view hides the lane WITHOUT forgetting which artefact it
    // held, so coming back up shows it again.
    this.panelTarget.classList.toggle("assistant-panel--artefact", this.artefactValue !== "")

    // The inline width belongs to the companion mode alone. In the full view the
    // width is the layout's (§7.7), and an inline style would outrank the class
    // that sets `width: auto` -- so it is CLEARED rather than overridden.
    this.panelTarget.style.width = full ? "" : `${this.clampedWidth()}px`

    // One button per action, each with a fixed accessible name; only which one is
    // visible changes. See the shell partial for why not one button that rewrites
    // its own label.
    if (this.hasExpandButtonTarget) this.expandButtonTarget.classList.toggle("hidden", full)
    if (this.hasCollapseButtonTarget) this.collapseButtonTarget.classList.toggle("hidden", !full)
    // A drag handle on an edge that is pinned to the viewport would promise a
    // width nobody can change.
    if (this.hasResizeHandleTarget) this.resizeHandleTarget.classList.toggle("hidden", full)
    // The overlay list has nothing to offer while the lane is standing there:
    // its button would load the SAME list a second time, into the chat frame,
    // and the panel would show the conversation list twice next to itself.
    if (this.hasHistoryButtonTarget) this.historyButtonTarget.classList.toggle("hidden", full)

    this.applyShift(document.body)
  }

  trapMobileFocus(event) {
    if (window.innerWidth >= FULL_PAGE_BELOW_PX || event.key !== 'Tab') return
    const items = [...this.panelTarget.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), [contenteditable="true"], [tabindex="0"]')].filter(item => item.getClientRects().length)
    const first = items[0], last = items[items.length - 1]
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
  }

  isFull() {
    return this.openValue && this.modeValue === this.fullModeValue
  }

  // Publishes the offset and the open state on the body. `root` is a <body>:
  // either the live one or turbo:before-render's incoming one, which is why this
  // takes the body rather than reaching for document.
  //
  // Deliberately NO width check here. Whether the offset applies is a question
  // about the viewport, and that belongs in the media query in
  // components/assistant_panel.css, next to the panel's own `hidden lg:block`.
  // Asking window.innerWidth in JavaScript instead meant a second copy of the
  // breakpoint that only refreshed when something happened to call this — so a
  // window grown past 1024px left the panel lying on top of the page.
  applyShift(root) {
    if (!root) return
    // No offset in the full view: the panel COVERS the page there instead of
    // standing next to it, so there is nothing to push aside. The media query's
    // own fallback (16rem, the bare sidebar) is the correct resting place, and
    // AssistantPanelState#content_offset answers nil for the same reason.
    if (this.openValue && !this.isFull()) {
      root.style.setProperty("--assistant-panel-offset", `${this.sidebarWidthValue + this.clampedWidth()}px`)
    } else {
      root.style.removeProperty("--assistant-panel-offset")
    }
    // Drives the content offset AND the list-lane collapse in layout.css (L12).
    root.classList.toggle(this.openClass, this.openValue)
    // Locks the covered page's scrolling (components/assistant_panel.css).
    root.classList.toggle(this.fullClass, this.isFull())
    this.syncTrigger(root)
  }

  // The sidebar row lives outside this controller's scope (it is part of the
  // navigation partial), so its active look is set from here.
  syncTrigger(root) {
    const trigger = root.querySelector("#assistant-panel-trigger")
    if (!trigger) return
    for (const cls of ["bg-cream-200", "border-l-ink", "font-semibold", "text-cream-900"]) {
      trigger.classList.toggle(cls, this.openValue)
    }
    trigger.setAttribute("aria-expanded", this.openValue ? "true" : "false")
  }

  // --- lazy frame -----------------------------------------------------------

  // The body is fetched the first time the panel is opened and then lives on the
  // permanent node. Setting src again on every open would throw the loaded
  // transcript (and the typed draft) away.
  loadFrame() {
    if (!this.hasFrameTarget) return
    if (this.frameTarget.getAttribute("src")) return
    this.frameTarget.setAttribute("src", this.srcValue)
  }

  // --- opening a specific thread --------------------------------------------

  // assistant_chats#show hands its thread over as ?assistant_chat_id=… on a real
  // page (L11: the thread has no page of its own). It has to be read from the
  // URL rather than from a server-rendered attribute, because a permanent node
  // NEVER sees the incoming markup: Turbo keeps this element and discards the
  // freshly rendered one, attributes included. The URL is the one channel the
  // server still has to a node it cannot re-render.
  honourRequestedChat() {
    const requested = new URLSearchParams(window.location.search).get("assistant_chat_id")
    if (!requested) return
    // Once per id: coming back to the same address later must not throw away a
    // draft the user has been typing since.
    if (this.element.dataset.honouredChat === requested) return
    this.element.dataset.honouredChat = requested

    this.openValue = true
    this.persist()
    this.render()
    this.frameTarget.setAttribute("src", `${this.srcValue}?chat_id=${encodeURIComponent(requested)}`)
  }

  // --- the full view (S3c T2, plan §4, L11) ---------------------------------

  // The third state of the SAME chat, not a page: only a class changes, so the
  // chat frame is never re-fetched and a typed draft, the scroll position and a
  // streaming answer all survive the way up.
  expandToFull() {
    this.modeValue = this.fullModeValue
    this.persist()
    this.render()
    this.loadHistoryLane()
  }

  collapseToPanel() {
    this.modeValue = this.panelModeValue
    this.persist()
    this.render()
  }

  // Lazy arm, mirroring loadFrame: the first expansion pays for the lane, the
  // transplants after it do not.
  armHistoryLane() {
    if (!this.hasHistoryFrameTarget) return
    if (this.historyFrameTarget.getAttribute("src")) return

    this.loadHistoryLane()
  }

  // The lane is lazy like the body: somebody who never expands never pays for
  // it. Loaded with the open thread as ?current= so the right row is marked,
  // exactly like showHistory does for the overlay list.
  loadHistoryLane() {
    if (!this.hasHistoryFrameTarget) return

    const url = new URL(this.srcValue, window.location.origin)
    url.searchParams.set("list", "1")
    url.searchParams.set("lane", "1")
    const open = this.openThreadId()
    if (open) url.searchParams.set("current", open)

    const target = url.toString()
    // Same address means Turbo would not re-fetch, and the lane can be stale for
    // a reason the address does not carry: a thread created since it loaded.
    if (this.historyFrameTarget.getAttribute("src") === target) this.historyFrameTarget.reload()
    else this.historyFrameTarget.setAttribute("src", target)
  }

  // Nothing tells the lane that the conversation next to it changed -- they are
  // two frames. Every load of the CHAT frame does: it moves the highlight and
  // picks up a thread that was just created. Only in the full view; in companion
  // mode the lane is display:none and re-fetching it would be pure cost.
  handleChatFrameLoad(event) {
    if (event.target !== this.frameTarget) return
    // Before the full-view early return: the chat frame carries the reference
    // chip, so a thread switch changes the answer to "does a reference already
    // stand, and is it this page's object?" -- in the companion mode just as
    // much as in the full view. It is also the FIRST answer to that question
    // (see chatFrameSeen in offerPageContext).
    this.chatFrameSeen = true
    // A freshly loaded transcript (first open, a thread picked from the list,
    // the full view after a hard reload) is read from its end.
    this.showTranscriptEnd()
    this.offerPageContext()
    // ...and again on the next frame, because since 27.08.2026 the offer strip
    // is part of THIS frame's response (Neo::Chat::ContextOfferComponent). A
    // load therefore hands us a fresh, empty strip, and Stimulus discovers its
    // targets through a MutationObserver -- one microtask later than this event.
    // The call above may still have been talking to the outgoing node, in which
    // case the offer would stay hidden until some unrelated navigation raised it
    // again. showOffer is idempotent (it compares what the strip already says),
    // so the repeat costs nothing when the first call did land.
    requestAnimationFrame(() => this.offerPageContext())
    if (!this.isFull()) return

    this.loadHistoryLane()
  }

  // --- earlier conversations (S3c T1, plan §7.6) -----------------------------

  // The list is a STATE OF THE FRAME, reached the same way ?new=1 is. Its button
  // cannot be a plain link, though: it sits in the permanent shell, which is
  // rendered once per page and never learns which thread the frame ended up
  // showing (Turbo keeps this element and throws the freshly rendered one away,
  // attributes included). So the address is built here, from what the DOM says
  // is open.
  showHistory() {
    if (!this.hasFrameTarget) return
    if (window.innerWidth < FULL_PAGE_BELOW_PX && this.artefactValue) this.closeArtefact()
    // Already showing the list IN THE CHAT FRAME: stop here. Asking again would
    // rebuild the address from openThreadId(), which reads that frame -- and the
    // list deliberately renders without one. The second request would go out
    // without ?current=, and the list would come back with nothing marked and a
    // back arrow pointing at the panel default, i.e. the NEWEST thread rather
    // than the one this was opened from. Silently switching the conversation
    // under somebody who only pressed a button twice.
    //
    // ⚠️ The FRAME, not this.element. The first version asked the whole panel
    // node, which was right while the overlay was the only surface rendering
    // this component. T2 gave the full view a history LANE inside the same node:
    // one trip up there loads it, the marker then stays in the DOM (the lane is
    // only display:none afterwards), and the button did nothing for the rest of
    // that browser's life. Found in production, not in a test -- the trip up and
    // back was never part of a history example.
    if (this.frameTarget.querySelector("[data-assistant-history]")) return

    const url = new URL(this.srcValue, window.location.origin)
    url.searchParams.set("list", "1")
    const open = this.openThreadId()
    if (open) url.searchParams.set("current", open)

    this.frameTarget.setAttribute("src", url.toString())
  }

  // The gear. Same shape as showHistory above and for the same two reasons: the
  // settings replace the transcript IN THIS FRAME, and the way back out has to
  // land on the conversation the gear was pressed on -- which only the browser
  // knows, because the header is a permanent node the server never re-renders.
  //
  // The already-showing guard is not defensive padding. Without it a second press
  // rebuilds the address from a chat frame that is no longer in the document,
  // openThreadId() comes back empty, and the back arrow silently points at the
  // panel default, i.e. the newest thread. That is switching the conversation
  // under somebody who only pressed a button twice -- the exact bug the history
  // list carries its own guard for.
  showSettings() {
    if (!this.hasFrameTarget) return
    if (window.innerWidth < FULL_PAGE_BELOW_PX && this.artefactValue) this.closeArtefact()
    if (this.frameTarget.querySelector("[data-assistant-settings]")) return

    const url = new URL(this.srcValue, window.location.origin)
    url.searchParams.set("settings", "1")
    const open = this.openThreadId()
    if (open) url.searchParams.set("current", open)

    this.frameTarget.setAttribute("src", url.toString())
  }

  // The chat frame says which thread it holds (ChatContainerComponent). Asked
  // for by the panel's OWN frame id rather than by the attribute alone: the list
  // this button opens carries a data-chat-id per row, and a bare attribute
  // selector would happily return the first of those instead.
  //
  // Absent while the panel shows the empty composer or the list itself — and
  // then there is genuinely nothing to come back to, so the list falls back to
  // the panel's default thread.
  openThreadId() {
    const frame = this.element.querySelector("#assistant-panel-chat")
    return frame ? frame.dataset.chatId : null
  }

  // The shareable address (assistant_panels#full) hands the full view over as
  // ?assistant=full, for the same reason ?assistant_chat_id= exists: a permanent
  // node never sees the markup the server rendered for it, so the URL is the one
  // channel left.
  //
  // Marked once per address, exactly like honourRequestedChat marks its id. Turbo
  // renders a morph refresh on the SAME url after every finished answer, and
  // without the marker that would undo a collapse the user had just done.
  honourRequestedMode() {
    const requested = new URLSearchParams(window.location.search).get("assistant")
    if (requested !== this.fullModeValue) return

    const marker = window.location.pathname + window.location.search
    if (this.element.dataset.honouredMode === marker) return
    this.element.dataset.honouredMode = marker

    this.openValue = true
    this.modeValue = this.fullModeValue
    this.persist()
    this.render()
    this.loadFrame()
    this.armHistoryLane()
  }

  // --- the artefact lane (S3c T3, plan §4, §8.1) -----------------------------

  // One click handler for the whole panel, with two jobs that belong together
  // because both answer the question "where does this link go".
  handleClick(event) {
    const anchor = event.target.closest("a[href]")
    if (!anchor || !this.element.contains(anchor)) return
    // A click the user asked to send SOMEWHERE ELSE is none of this handler's
    // business, and both jobs below get it wrong: preventDefault() would swallow
    // the new tab, and the step-down would fold the panel away although the page
    // it stands on never navigates (Turbo ignores modified clicks too). Same for
    // a click something upstream already answered.
    if (event.defaultPrevented) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return

    // On phones the artefact replaces the chat lane. A shell action such as
    // "new chat" must reveal the frame it is about to load.
    if (window.innerWidth < FULL_PAGE_BELOW_PX && this.artefactValue && anchor.dataset.turboFrame === this.frameTarget.id) this.closeArtefact()

    // 1. A source with an artefact of its own opens the LANE instead of
    //    navigating -- but only in the full view, which is the only state that
    //    has a lane. In the companion mode the real page next door is the better
    //    answer and the link already points there (§4).
    const artefact = anchor.dataset.assistantArtefact
    if (artefact && this.isFull()) {
      event.preventDefault()
      this.openArtefact(artefact)
      return
    }

    // Mobile navigation is handled by turbo:visit, after any confirmation.
    if (window.innerWidth < FULL_PAGE_BELOW_PX || !this.isFull()) return
    // 2. Anything that LEAVES the panel while the panel covers the page: step
    //    back down, otherwise the page loads behind a full-screen panel and the
    //    click looks like it did nothing. That was the state T2 shipped in.
    //    A link that targets a frame INSIDE the panel (the history rows, "new
    //    chat") is not leaving, and a new tab does not touch this page at all.
    //    Neither does an in-page anchor or a mailto:/tel: link, which an answer
    //    can perfectly well contain -- folding the panel away for one of those
    //    would take the conversation off screen for nothing.
    if (anchor.target === "_blank") return
    const frame = anchor.dataset.turboFrame
    if (frame && frame !== "_top") return
    const href = anchor.getAttribute("href")
    if (!href || href.startsWith("#")) return
    if (anchor.protocol && !["http:", "https:"].includes(anchor.protocol)) return

    this.collapseToPanel()
  }

  // The lane opens in the full view by definition: opening one in the companion
  // mode would set a state with nowhere to appear.
  openArtefact(query) {
    this.artefactValue = query
    this.modeValue = this.fullModeValue
    this.persist()
    this.render()
    this.loadArtefact()
    this.armHistoryLane()
    this.publishArtefactAddress()
  }

  // Hidden, not thrown away: the frame keeps what it holds, so closing and
  // reopening the same report costs nothing. The address goes, because that is
  // what a shared link and a reload read.
  closeArtefact() {
    this.artefactValue = ""
    this.render()
    this.publishArtefactAddress()
  }

  loadArtefact() {
    if (!this.hasArtefactFrameTarget || !this.artefactValue) return

    // The endpoint is OURS (a Stimulus value the server rendered); only the query
    // comes from the link or the address. Never the other way round -- a frame
    // src taken whole from a parameter would let the address decide which page
    // the panel loads.
    const target = `${this.artefactSrcValue}?${this.artefactValue}`
    // Same address means Turbo would not re-fetch, and a report can be stale for
    // a reason the address does not carry: somebody booked an hour since.
    if (this.artefactFrameTarget.getAttribute("src") === target) this.artefactFrameTarget.reload()
    else this.artefactFrameTarget.setAttribute("src", target)
  }

  // §13-10: the open panel belongs in the address. Here it is written rather than
  // navigated to -- replaceState, because opening a panel is not a page visit and
  // must not push a history entry per source click. What it buys: a reload keeps
  // the lane, and the link can be handed on.
  //
  // The node stays the OWNER of the state (that is what survives the morph after
  // every answer, R-M3); the address is the way in and back.
  publishArtefactAddress() {
    const url = new URL(window.location.href)
    if (this.artefactValue) url.searchParams.set("assistant_artefact", this.artefactValue)
    else url.searchParams.delete("assistant_artefact")

    window.history.replaceState(window.history.state, "", url.toString())
    // Ours now: without this the next connect would read the address we just
    // wrote as a fresh request and re-open what the user may have just closed.
    this.element.dataset.honouredArtefact = url.pathname + url.search
  }

  // Entering through the address, marked once like ?assistant_chat_id= and
  // ?assistant=full, and for the same reason: a permanent node never sees what
  // the server rendered for it, and the morph refresh after every answer would
  // otherwise undo a close the user had just done.
  honourRequestedArtefact() {
    const requested = new URLSearchParams(window.location.search).get("assistant_artefact")
    if (!requested) return

    const marker = window.location.pathname + window.location.search
    if (this.element.dataset.honouredArtefact === marker) return
    this.element.dataset.honouredArtefact = marker

    this.openValue = true
    this.openArtefact(requested)
  }

  // --- surviving the transplant ---------------------------------------------

  // The one thing data-turbo-permanent does NOT carry across a visit: the cable
  // subscription. <turbo-cable-stream-source> unsubscribes in its
  // disconnectedCallback and re-subscribes asynchronously in connectedCallback,
  // and ActionCable has no replay — a broadcast that lands inside that window is
  // gone. It only MATTERS while an answer is outstanding (every delta is a full
  // replace of the bubble, so an earlier one repairs itself; the final one does
  // not), so that is the only case that re-fetches. Re-fetching on every
  // navigation would give away exactly what the permanent node bought us.
  //
  // Draft text and its explicit revision binding live inside the replaced frame.
  // Restore both together, and only into the same conversation form.
  resyncIfAwaitingAnswer() {
    const marker = this.awaitingAnswerMarker()
    if (!marker) return
    if (!this.claimResync(marker)) return

    const field = this.composerField()
    const draft = field ? field.value : ""
    const formAction = field?.form?.action
    const revisionFields = ["chatpost[revision_answer_id]", "chatpost[revision_answer_key]", "chatpost[ticket_suggestion_meeting_id]"]
    const revision = revisionFields.map(name => [name, field?.form?.elements.namedItem(name)?.value || ""])
    const hadFocus = field ? document.activeElement === field : false

    this.element.addEventListener("turbo:frame-load", () => {
      const restored = this.composerField()
      if (!restored || restored.form?.action !== formAction) return
      restored.value = draft
      for (const [name, value] of revision) {
        const input = restored.form.elements.namedItem(name)
        if (input) input.value = value
      }
      restored.dispatchEvent(new Event("input", { bubbles: true }))
      if (hadFocus) restored.focus()
    }, { once: true })

    const url = this.resyncUrl()
    if (this.frameTarget.getAttribute("src") === url) this.frameTarget.reload()
    else this.frameTarget.setAttribute("src", url)
  }

  // The frame's src is NOT always the address worth re-fetching. "Neuer Chat" is
  // a link that navigates the frame, so Turbo points src at ?new=1 -- and
  // assistant_chats#create then fills the frame with a real conversation without
  // touching src, because it answers with an `update` (which is what keeps the
  // src alive in the first place). Reloading ?new=1 at that moment answers with
  // the empty state, and the question the user just asked disappears from the
  // panel while its answer is still being written.
  //
  // A rendered transcript is the signal that ?new=1 has been spent: the same
  // [data-chat-role] bubbles awaitingAnswerMarker reads.
  resyncUrl() {
    const current = this.frameTarget.getAttribute("src")
    if (!current) return this.srcValue

    const url = new URL(current, window.location.origin)
    if (this.element.querySelector("[data-chat-role]")) url.searchParams.delete("new")
    return url.toString()
  }

  // The id of the last bubble WHILE an answer is outstanding, otherwise null.
  // "Outstanding" is either an assistant bubble that has not finished or a
  // question whose answer has not appeared at all. Both are read off the LAST
  // bubble, because that is the only one a missed broadcast could concern.
  awaitingAnswerMarker() {
    if (!this.hasFrameTarget || !this.frameTarget.getAttribute("src")) return null

    const bubbles = this.element.querySelectorAll("[data-chat-role]")
    const last = bubbles[bubbles.length - 1]
    if (!last) return null
    // Structured tasks refresh their own authorized result fragment.
    if (last.querySelector('[data-controller="assistant-suggestion-result"]')) return null

    // Anything that is not a finished assistant answer means we are still
    // waiting. Asking for role "user" specifically missed the very first
    // question of a thread, which set_initial_role forces to "system".
    const waiting = last.dataset.chatRole !== "assistant" || last.dataset.answerPending === "true"
    return waiting ? last.id : null
  }

  // Bounded on purpose. A thread whose answer never arrived — a job that died
  // between the question and the placeholder — stays "waiting" forever, and
  // without a cap every single navigation for the rest of that session would
  // re-fetch the transcript. The count resets as soon as the conversation
  // actually moves on, so the protection is back for the next answer.
  claimResync(marker) {
    const repeat = this.element.dataset.resyncMarker === marker
    const count = repeat ? Number(this.element.dataset.resyncCount || 0) : 0
    if (count >= RESYNC_ATTEMPTS) return false

    this.element.dataset.resyncMarker = marker
    this.element.dataset.resyncCount = String(count + 1)
    return true
  }

  // --- resize ---------------------------------------------------------------

  // The handle carries role="separator", so it has to be operable without a
  // pointer -- an ARIA role that promises keyboard operation and then ignores
  // every key is worse than no role. Arrow keys step, Home/End jump to the
  // bounds, and aria-valuenow is kept in step with the width.
  resizeByKey(event) {
    const steps = {
      ArrowLeft: -RESIZE_STEP, ArrowRight: RESIZE_STEP,
      Home: this.minWidthValue - this.clampedWidth(), End: this.maxWidthValue - this.clampedWidth(),
    }
    const delta = steps[event.key]
    if (delta === undefined) return

    event.preventDefault()
    this.widthValue = this.clampedWidth() + delta
    this.panelTarget.style.width = `${this.clampedWidth()}px`
    this.applyShift(document.body)
    this.syncHandleValue(event.currentTarget)
    this.persist()
  }

  syncHandleValue(handle) {
    if (!handle) return
    handle.setAttribute("aria-valuenow", String(this.clampedWidth()))
  }

  startResize(event) {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = this.panelTarget.getBoundingClientRect().width
    const main = document.querySelector("main")
    const previousTransition = main ? main.style.transition : ""
    // The offset has to track the pointer, not trail it by the 500ms layout
    // transition — with the transition on, the content visibly lags the handle.
    if (main) main.style.transition = "none"
    document.body.style.userSelect = "none"

    const move = (moveEvent) => {
      this.widthValue = startWidth + (moveEvent.clientX - startX)
      this.panelTarget.style.width = `${this.clampedWidth()}px`
      this.applyShift(document.body)
    }
    // pointercancel matters: a drag interrupted by the browser (a touch turned
    // into a scroll, the window losing the pointer) never fires pointerup, and
    // without this the page would keep userSelect:none and a dead transition
    // override for the rest of the session — nothing on the page selectable any
    // more, with no visible cause.
    const up = () => {
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      window.removeEventListener("pointercancel", up)
      if (main) main.style.transition = previousTransition
      document.body.style.userSelect = ""
      this.syncHandleValue(event.currentTarget)
      this.persist()
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
    window.addEventListener("pointercancel", up)
  }

  clampedWidth() {
    return Math.min(Math.max(this.widthValue || this.minWidthValue, this.minWidthValue), this.maxWidthValue)
  }

  // --- state ----------------------------------------------------------------

  // "<0|1>:<width>", the format AssistantPanelState parses. Written from here so
  // the SERVER can paint the correct geometry after a hard reload; the node keeps
  // the same state across transplants on its own.
  persist() {
    // "<0|1>:<width>:<mode>", the format AssistantPanelState parses. The mode is
    // appended, and the server's regex keeps the third group optional, so the
    // two-part cookies already sitting in every browser go on being understood.
    const mode = this.modeValue === this.fullModeValue ? this.fullModeValue : this.panelModeValue
    const value = `${this.openValue ? 1 : 0}:${this.clampedWidth()}:${mode}`
    const year = 60 * 60 * 24 * 365
    // Secure only over https: setting it on plain http (development) would make
    // the browser drop the cookie, and the panel would forget its state on every
    // reload for exactly the people working on it.
    const secure = window.location.protocol === "https:" ? "; Secure" : ""
    document.cookie = `${this.cookieNameValue}=${value}; path=/; max-age=${year}; SameSite=Lax${secure}`
  }

  // --- scrolling ------------------------------------------------------------

  // NEVER read scrollTop in disconnect(): by then Turbo has already detached the
  // node and every container reports 0. Remembering it on the scroll event is
  // the only reading that happens while the element is still in the document.
  rememberTranscriptScroll(container) {
    this.element.dataset.transcriptScroll = String(container.scrollTop)
  }

  restoreTranscriptScroll() {
    const saved = this.element.dataset.transcriptScroll
    if (!saved) return
    const container = this.transcriptContainer()
    if (container) container.scrollTop = parseInt(saved, 10)
  }

  transcriptContainer() {
    return this.element.querySelector('[role="log"]')
  }

  // The end of the conversation is what the reader came for: the last thing
  // said. Called when the panel opens and when the chat frame loads -- NOT on
  // connect(), which also fires on every transplant and would throw away the
  // position restoreTranscriptScroll just brought back. Remembered right away
  // for the same reason: the next transplant restores what was last remembered,
  // and without this line that would be the position from BEFORE the jump.
  // Nothing to do while the frame shows the list or the settings (no log).
  showTranscriptEnd() {
    const container = this.transcriptContainer()
    if (!container) return

    container.scrollTop = container.scrollHeight
    this.rememberTranscriptScroll(container)
  }

  handleScroll(event) {
    const target = event.target === document ? document.scrollingElement : event.target
    if (!target || !(target instanceof Element)) return

    // Scrolling INSIDE the panel is the transcript, not the page.
    if (this.element.contains(target)) {
      if (target.matches('[role="log"]')) this.rememberTranscriptScroll(target)
      return
    }
    this.shrinkCapsuleOnScroll(target)
  }

  // While the page scrolls the capsule gets out of the way of the last row;
  // scrolling back up brings it out again. Typing in it is never interrupted.
  shrinkCapsuleOnScroll(target) {
    if (this.openValue || !this.hasCapsuleTarget) return
    if (document.activeElement === this.capsuleInputTarget) return

    const top = target.scrollTop || 0
    const last = this.lastScrollTops.get(target)
    this.lastScrollTops.set(target, top)
    if (last === undefined) return
    if (top > last + 2) this.shrinkCapsule()
    else if (top < last - 2) this.expandCapsule()
  }

  shrinkCapsule() {
    this.capsuleInputTarget.classList.add("hidden")
    this.capsuleMiniTarget.classList.remove("hidden")
    this.capsuleMiniTarget.classList.add("flex")
  }

  expandCapsule() {
    this.capsuleMiniTarget.classList.add("hidden")
    this.capsuleMiniTarget.classList.remove("flex")
    this.capsuleInputTarget.classList.remove("hidden")
  }

  // --- helpers --------------------------------------------------------------

  // The composer field, whichever of the two shapes is currently rendered (reply
  // form or first-message form). Looked up rather than targeted: it arrives with
  // the frame, and targets inside a lazily loaded frame are not there at connect.
  composerField() {
    return this.element.querySelector('[data-neo-chat-composer-target="field"]')
  }

  // On the FIRST open the frame has only just been armed and its fetch is still
  // in flight, so the composer does not exist yet — anything that wants to touch
  // it has to be able to wait. Without this the question typed into the capsule
  // was silently dropped exactly once per session: on the first use.
  //
  // Retries once. If the frame comes back WITHOUT a composer (the org's AI is
  // unavailable, so the panel renders the reason instead), waiting longer would
  // not help.
  whenComposerReady(callback, retry = true) {
    const field = this.composerField()
    if (field) return callback(field)
    if (!retry) return

    this.element.addEventListener("turbo:frame-load", () => this.whenComposerReady(callback, false), { once: true })
  }

  focusComposer() {
    this.whenComposerReady((field) => field.focus())
  }
}
