import { Controller } from "@hotwired/stimulus"
import SlimSelect from "slim-select"
import { parseParticipants } from "meetings/participant_parser"
import { normalizeName } from "meetings/name_normalizer"
import { mergeDetections } from "meetings/participant_merge"

// Participant picker for the meeting form (Slice 1b + Slice 5, reworked to a
// native <select multiple> + SlimSelect). A name-like text input gets Safari's
// macOS Contacts autofill overlaid on it regardless of autocomplete="off" /
// type="search" (both verified ignored on prod); a <select> widget does not, so
// this mirrors the working ticket-assignee field.
//
// Submit contract = "Option C" (presentational SlimSelect + mirrored hidden
// inputs): the <select> carries NO participants name. On every change this
// controller rebuilds indexed hidden inputs
//   meeting[participants][i][display_name] + [i][user_id]   (i ≥ 1)
// next to a static blank index-0 sentinel (in the ERB) that keeps the key present
// so "removed everyone" reconciles to zero. The server, Actors::SaveMeeting and
// meeting_params are therefore untouched. The option VALUE encodes the link:
// "user:<uuid>" → project/org member (user_id), any other value → external name.
//
// Two feeds add names to the selection (both go through selectNames → match an
// existing option or create+select an external one):
//   - the offline transcript parser (Slice 1b, client-only, paste-triggered);
//   - the LLM detection leg (Slice 5, button in offline mode / debounced auto-POST
//     in AI mode). Its merge rule (participant_merge.js, contract-tested) only ever
//     ADDS — names the user removed (tracked as dismissals via the selection diff)
//     are never resurrected. The org AI gate is decided SERVER-SIDE: without
//     ai_available? there is no button, no detect URL and no AI mode.
export default class extends Controller {
  static targets = ["select", "hiddenInputs", "announcer", "transcript", "detectButton"]
  static values = {
    // --- SlimSelect UI copy ---
    placeholderText: String,
    addableText: String, // "{value}" placeholder replaced by SlimSelect
    searchEmptyText: String,
    // --- offline parser / shared announce copy ---
    noSpeakersText: String,
    detectedText: String, // "{count}" placeholder, filled in JS
    // --- LLM detection (Slice 5); detectUrl is only rendered when the org has AI
    // available, detectionMode is the server-resolved effective mode ---
    detectUrl: String,
    detectionMode: String,
    aiAvailable: Boolean,
    detectingText: String,
    detectFailedText: String,
    detectRateLimitedText: String, // shown on 429 (throttle) instead of the generic failure
    detectTooLargeText: String, // "{max_kb}" placeholder, filled in JS
    maxBytes: Number, // mirrors the server MAX_DETECT_BYTES cap (0 = no client guard)
    aiDetectedText: String, // "{count}" placeholder, filled in JS
    aiNoneDetectedText: String
  }

  // Auto-detection in AI mode fires at the earliest this long after the last
  // transcript change (Eng-Review D5: hectic editing must not spam the LLM).
  static AUTO_DETECT_DEBOUNCE_MS = 1500

  connect() {
    // LLM merge rule, case "removed by the user": a name whose token the user
    // deleted must never be re-added by a later LLM run. Tracked via the selection
    // diff in onSelectionChange (SlimSelect has no per-token remove event we need).
    // The offline parser deliberately ignores dismissals (re-paste re-proposes).
    this.dismissedKeys = new Set()
    this.prevKeys = new Set() // normalized names selected as of the last change
    this.detectAbort = null
    this.detectDebounce = null

    this.initSlimSelect()

    // afterChange does not fire for the options pre-selected at init (Edit form), so
    // seed prevKeys and mirror the initial selection into the hidden inputs once.
    this.prevKeys = this.selectedKeys()
    this.mirror(this.selectedOptions())
    this.updateDetectButtonState()

    // SlimSelect debounces afterChange by 100ms, so a submit fired right after a
    // selection change could serialize stale hidden inputs. Re-mirror synchronously
    // on submit (before Turbo's document-level handler) as the correctness guarantee.
    this.form = this.element.closest("form")
    if (this.form) {
      this.boundSyncOnSubmit = () => this.mirror(this.selectedOptions())
      this.form.addEventListener("submit", this.boundSyncOnSubmit)
    }
  }

  disconnect() {
    clearTimeout(this.detectDebounce)
    this.detectAbort?.abort()
    if (this.slim) {
      this.slim.destroy()
      this.slim = null
    }
    if (this.hasSelectTarget) this.selectTarget.slim = null
    if (this.form && this.boundSyncOnSubmit) {
      this.form.removeEventListener("submit", this.boundSyncOnSubmit)
    }
  }

  // ---- SlimSelect init -----------------------------------------------------

  initSlimSelect() {
    const el = this.selectTarget
    if (el.slim) el.slim.destroy()

    try {
      this.slim = new SlimSelect({
        select: el,
        settings: {
          placeholderText: this.placeholderTextValue,
          searchText: this.searchEmptyTextValue,
          addableText: this.addableTextValue,
          allowDeselect: true,
          closeOnSelect: false,
          hideSelected: true
        },
        events: {
          afterChange: () => this.onSelectionChange(),
          // Typed text with no match → a new EXTERNAL option (no "user:" prefix).
          addable: (value) => this.addableOption(value)
        }
      })
      el.slim = this.slim
    } catch (error) {
      console.error("Error initializing SlimSelect (meeting participants):", error)
    }
  }

  // addable factory: returns the option info for a typed external name, or false
  // to reject an empty entry. The marker html keeps it visually consistent with
  // the server-rendered external options; the name is escaped for that innerHTML.
  addableOption(value) {
    const name = String(value || "").trim().replace(/\s+/g, " ")
    if (!name) return false
    return { text: name, value: name, html: this.externalOptionHtml(name) }
  }

  // ---- selection → hidden inputs (the Option C mirror) ---------------------

  onSelectionChange() {
    const options = this.selectedOptions()
    const newKeys = new Set(options.map((o) => normalizeName(o.text)))

    // Anything selected before and gone now was removed by the user → dismiss it so
    // a later LLM run cannot bring it back.
    for (const key of this.prevKeys) {
      if (!newKeys.has(key)) this.dismissedKeys.add(key)
    }
    this.prevKeys = newKeys
    this.mirror(options)
  }

  mirror(options) {
    this.hiddenInputsTarget.innerHTML = ""
    options.forEach((opt, i) => {
      const idx = i + 1 // index 0 is the static blank sentinel in the ERB
      const { userId, displayName } = this.decodeOption(opt)
      this.hiddenInputsTarget.appendChild(this.hiddenField(`meeting[participants][${idx}][display_name]`, displayName))
      this.hiddenInputsTarget.appendChild(this.hiddenField(`meeting[participants][${idx}][user_id]`, userId))
    })
  }

  // "user:<uuid>" → linked member (user_id); anything else → external name.
  decodeOption(opt) {
    const value = String(opt.value ?? "")
    if (value.startsWith("user:")) return { userId: value.slice(5), displayName: opt.text }
    return { userId: "", displayName: opt.text }
  }

  hiddenField(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    return input
  }

  // ---- adding names (parser + LLM feed through here) -----------------------

  // For each name: select the existing option that matches by normalized name
  // (member OR external), else create + select a new external option. Returns the
  // number of names that became newly selected (for the announcer copy).
  selectNames(names) {
    const optionByKey = this.optionValueByKey()
    const selected = new Set(this.selectedValues())
    const before = selected.size

    names.forEach((raw) => {
      const name = String(raw || "").trim().replace(/\s+/g, " ")
      const key = normalizeName(name)
      if (!name || !key) return

      let value = optionByKey.get(key)
      if (!value) {
        value = name // external option: value === display name
        this.slim.addOption({ text: name, value, html: this.externalOptionHtml(name) })
        optionByKey.set(key, value)
      }
      selected.add(value)
    })

    // Union of prior + new — never deselects. Fires afterChange → mirror.
    this.slim.setSelected([...selected])
    return selected.size - before
  }

  // normalized name → option value, across all current options (members first, so
  // a member option wins a name collision with an external suggestion).
  optionValueByKey() {
    const map = new Map()
    this.eachOption((o) => {
      const key = normalizeName(o.text)
      if (key && !map.has(key)) map.set(key, o.value)
    })
    return map
  }

  selectedOptions() {
    const selected = []
    this.eachOption((o) => {
      if (o.selected) selected.push(o)
    })
    return selected
  }

  selectedValues() {
    return this.selectedOptions().map((o) => o.value)
  }

  selectedKeys() {
    return new Set(this.selectedOptions().map((o) => normalizeName(o.text)))
  }

  // Iterates the SlimSelect store options (flattening any optgroups — we have none,
  // but stay defensive). Reading the store keeps custom data off the DOM round-trip.
  eachOption(fn) {
    if (!this.slim) return
    for (const d of this.slim.getData()) {
      if (d.options) d.options.forEach(fn)
      else fn(d)
    }
  }

  externalOptionHtml(name) {
    return `<i class="bi bi-person-dash" aria-hidden="true"></i> ${this.escapeHtml(name)}`
  }

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  // ---- offline transcript parser (Slice 1b) --------------------------------

  onTranscriptPaste() {
    // Read AFTER the paste has landed in the textarea, then parse the whole field.
    setTimeout(() => {
      this.runParser()
      this.updateDetectButtonState()
      this.scheduleAutoDetection()
    }, 0)
  }

  // Any transcript edit (input event): the offline parser keeps its Slice 1b
  // paste-only trigger, but the button availability follows the field content and
  // the AI-mode auto-detection debounces on every change.
  onTranscriptInput() {
    this.updateDetectButtonState()
    this.scheduleAutoDetection()
  }

  runParser() {
    if (!this.hasTranscriptTarget) return

    const names = parseParticipants(this.transcriptTarget.value, normalizeName)
    const added = this.selectNames(names)

    if (added > 0) {
      this.announce((this.detectedTextValue || "{count}").replace("{count}", String(added)))
    } else if (names.length === 0) {
      this.announce(this.noSpeakersTextValue)
    }
  }

  announce(message) {
    if (this.hasAnnouncerTarget && message) this.announcerTarget.textContent = message
  }

  // ---- LLM detection (Slice 5) ---------------------------------------------
  // Server-side gating first: without org ai_available? there is no button, no
  // detect URL and no AI mode — none of this can ever fire. All status/error copy
  // goes through the visible aria-live announcer; the current selection is NEVER
  // dropped by a failed or successful detection run (merge only adds).

  // Button click ("Teilnehmer mit KI erkennen") — the offline-mode manual trigger.
  detectParticipants() {
    this.startDetection()
  }

  // AI mode only: debounce the auto-POST after the last transcript change and keep a
  // single in-flight request (a new run supersedes the old one).
  scheduleAutoDetection() {
    if (this.detectionModeValue !== "ai" || !this.aiAvailableValue || !this.detectUrlValue) return
    if (!this.transcriptText()) return

    clearTimeout(this.detectDebounce)
    this.detectDebounce = setTimeout(() => this.startDetection(), this.constructor.AUTO_DETECT_DEBOUNCE_MS)
  }

  async startDetection() {
    const transcript = this.transcriptText()
    if (!transcript || !this.detectUrlValue || !this.aiAvailableValue) return

    // Mirror the server MAX_DETECT_BYTES cap client-side: an oversized transcript
    // would be rejected 422 anyway AND still burn a throttle slot (Rack::Attack
    // counts before the controller check), so stop before the POST.
    if (this.maxBytesValue && this.byteSize(transcript) > this.maxBytesValue) {
      this.announce((this.detectTooLargeTextValue || "{max_kb}").replace("{max_kb}", String(Math.floor(this.maxBytesValue / 1024))))
      return
    }

    this.detectAbort?.abort()
    const abort = new AbortController()
    this.detectAbort = abort
    this.updateDetectButtonState()
    this.announce(this.detectingTextValue)

    try {
      const response = await fetch(this.detectUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          // Turbo only sets the token on form submits — a raw fetch POST must send
          // it itself or Rails rejects the request.
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ transcript }),
        signal: abort.signal
      })

      const payload = await this.readJson(response)
      if (response.ok && payload?.participants) {
        this.applyDetections(payload.participants.map((p) => p.display_name))
      } else if (response.status === 429) {
        // Throttle hit (Rack::Attack) → text/plain, no JSON error. In AI mode the
        // debounce can outrun the 10/min limit during normal editing, so name the
        // real cause instead of the generic "detection failed".
        this.announce(this.detectRateLimitedTextValue || this.detectFailedTextValue)
      } else {
        // 403 (AI gate) / 422 (limit, LLM/quota errors) carry a readable JSON error.
        this.announce(payload?.error || this.detectFailedTextValue)
      }
    } catch (error) {
      if (error.name === "AbortError") return
      this.announce(this.detectFailedTextValue)
    } finally {
      if (this.detectAbort === abort) {
        this.detectAbort = null
        this.updateDetectButtonState()
      }
    }
  }

  // MERGE (plan §5): the LLM only ever ADDS names — the pure rule lives in
  // participant_merge.js and is contract-tested under node:test. Survivors flow
  // through selectNames like the parser's.
  applyDetections(names) {
    const toAdd = mergeDetections({
      detected: names,
      existingKeys: this.selectedKeys(),
      dismissedKeys: this.dismissedKeys,
      normalize: normalizeName
    })

    const added = this.selectNames(toAdd)

    if (added > 0) {
      this.announce((this.aiDetectedTextValue || "{count}").replace("{count}", String(added)))
    } else {
      this.announce(this.aiNoneDetectedTextValue)
    }
  }

  transcriptText() {
    return this.hasTranscriptTarget ? this.transcriptTarget.value.trim() : ""
  }

  // UTF-8 byte length, matching Ruby's String#bytesize the server cap uses.
  byteSize(text) {
    return new TextEncoder().encode(text).length
  }

  // The button exists only when the org opted in (server-rendered); it is usable
  // only when AI is fully available AND there is a transcript AND no request is in
  // flight. Class toggles mirror Neo::Buttons::Base#disabled_classes.
  updateDetectButtonState() {
    if (!this.hasDetectButtonTarget) return

    const usable = this.aiAvailableValue && !!this.transcriptText() && !this.detectAbort
    const button = this.detectButtonTarget
    // The component's disabled look follows the attribute (Neo::Buttons::Base).
    button.disabled = !usable
  }

  readJson(response) {
    const type = response.headers.get("Content-Type") || ""
    if (!type.includes("application/json")) return Promise.resolve(null)
    return response.json().catch(() => null)
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
