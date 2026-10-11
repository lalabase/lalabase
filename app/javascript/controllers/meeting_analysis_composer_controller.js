import { Controller } from "@hotwired/stimulus"

// Works on both composer forms. References come from adopted chips, never page context.
export default class extends Controller {
  static targets = ["tools", "picker", "search", "list", "manage", "titleBox", "title", "status", "saveTemplate", "revision", "revisionId", "revisionKey", "chooseTemplate"]
  static values = { url: String, error: String, appended: String, empty: String, draft: Boolean, chatId: String }

  connect() {
    this.onDraftInput = () => this.syncRevision()
    this.onRequested = event => this.prepareAnalysis(event.detail?.meetingId)
    this.element.addEventListener("input", this.onDraftInput)
    this.element.addEventListener("assistant:analysis-request", this.onRequested)
    this.syncRevision()
    this.root = this.element.closest('#assistant_panel_body') || this.element.parentElement
    this.observer = new MutationObserver(() => this.syncReferences())
    this.observer.observe(this.root, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-reference-keys"] })
    this.syncReferences()
  }

  disconnect() {
    this.observer?.disconnect()
    this.element.removeEventListener("input", this.onDraftInput)
    this.element.removeEventListener("assistant:analysis-request", this.onRequested)
  }
  get field() { return this.element.querySelector('textarea[data-neo-chat-composer-target="field"]') }
  preventSubmit(event) { event.preventDefault(); event.stopPropagation() }

  syncReferences() {
    const keys = [...this.root.querySelectorAll('[data-reference-keys]')].flatMap(node => (node.dataset.referenceKeys || "").split(/\s+/))
    const ids = [...new Set(keys.filter(key => key.startsWith("Meeting:")).map(key => key.slice(8)))]
    const signature = ids.join(" ")
    if (signature === this.referenceSignature) return
    this.referenceSignature = signature
    if (this.preferredMeetingId && !ids.includes(this.preferredMeetingId)) this.preferredMeetingId = null
    this.meetingId = this.preferredMeetingId || ids[0]
    this.toolsTarget.hidden = !this.meetingId
    this.closePicker()
    this.titleBoxTarget.hidden = true
    this.saveTemplateTarget.hidden = true
    if (this.meetingId) {
      if (this.draftValue) this.toolsTarget.open = true
      this.load()
    }
  }

  // Resolves true only when the list was rebuilt for the meeting it was asked
  // about -- the one fact destroyTemplate needs before it may move focus into it.
  async load() {
    const id = this.meetingId
    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("meeting_id", id)
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (id !== this.meetingId) return false
      this.chooseTemplateTarget.hidden = response.status === 403
      this.manageTarget.hidden = true
      this.saveTemplateTarget.hidden = true
      if (response.status === 403) { this.prompts = []; this.filter(); return true }
      if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) throw new Error(this.errorValue)
      const result = await response.json()
      if (id !== this.meetingId) return false
      this.prompts = result.prompts
      this.canManage = result.can_manage
      this.manageTarget.hidden = !result.can_manage
      this.saveTemplateTarget.hidden = !result.can_manage
      this.filter()
      return true
    } catch (_) { this.statusTarget.textContent = this.errorValue; return false }
  }

  revise(event) {
    if (!this.hasRevisionTarget || event.detail.chatId !== this.chatIdValue) return
    this.element.dispatchEvent(new Event("assistant:normal-request"))
    this.revisionIdTarget.value = event.detail.id
    this.revisionKeyTarget.value = event.detail.key
    this.revisionTarget.hidden = false
    this.field.focus()
  }

  // The panel may restore the draft before or after this controller connects.
  syncRevision() {
    if (this.hasRevisionTarget) this.revisionTarget.hidden = !this.revisionIdTarget.value
  }

  cancelRevision() {
    if (!this.hasRevisionTarget) return
    this.revisionIdTarget.value = ""
    this.revisionKeyTarget.value = ""
    this.revisionTarget.hidden = true
  }

  prepareAnalysis(meetingId) {
    if (meetingId) {
      this.preferredMeetingId = meetingId
      this.referenceSignature = null
      this.syncReferences()
    }
    this.element.dispatchEvent(new Event("assistant:normal-request"))
    this.cancelRevision()
    this.toolsTarget.open = true
    this.field.focus()
  }

  example(event) { this.prefill(event.currentTarget.dataset.prompt) }
  prefill(text) {
    this.element.dispatchEvent(new Event("assistant:normal-request"))
    this.cancelRevision()
    const existing = this.field.value
    const append = existing.trim() !== ""
    // Append instead of overwriting: the complete draft remains editable in one field.
    this.field.value = append ? `${existing}\n\n${text}` : text
    this.field.dispatchEvent(new Event("input", { bubbles: true }))
    this.statusTarget.textContent = append ? this.appendedValue : ""
    this.closePicker()
    this.field.focus()
  }

  choose() { this.pickerTarget.hidden = false; this.titleBoxTarget.hidden = true; this.load(); this.searchTarget.focus() }
  title() { this.titleBoxTarget.hidden = false; this.closePicker(); this.titleTarget.focus() }
  toggleManage() { this.setManaging(!this.managing); this.filter() }

  // ⚠️ Management mode is a state of the OPEN picker, never a standing setting.
  // It used to survive everything: close the picker, adopt another meeting,
  // come back through "Vorlage wählen" -- and every row carried a delete button
  // again, for a library the user had not asked to manage this time. Every way
  // the picker goes away runs through here.
  closePicker() {
    this.pickerTarget.hidden = true
    if (this.managing) { this.setManaging(false); this.filter() }
  }

  // The <details> folding shut takes the picker out of view without hiding it,
  // so it ends management mode the same way (the picker itself stays as it was).
  toolsToggled() {
    if (!this.toolsTarget.open && this.managing) { this.setManaging(false); this.filter() }
  }

  // aria-pressed is the only thing that tells a screen reader this button is a
  // switch and which way it stands: its label never changes, only the rows do.
  // Written together with the flag so the two cannot drift apart.
  setManaging(managing) {
    this.managing = managing
    this.manageTarget.setAttribute("aria-pressed", String(managing))
  }

  filter() {
    const query = this.searchTarget.value.toLocaleLowerCase()
    this.listTarget.replaceChildren()
    const matches = (this.prompts || []).filter(p => `${p.title} ${p.prompt_text}`.toLocaleLowerCase().includes(query))
    for (const [index, prompt] of matches.entries()) {
      const row = document.createElement("div")
      row.className = "flex items-center gap-2"
      const choose = document.createElement("button")
      choose.type = "button"
      choose.className = "min-w-0 flex-1 text-left rounded px-2 py-1.5 hover:bg-cream-100"
      choose.textContent = prompt.title
      choose.addEventListener("click", () => this.prefill(prompt.prompt_text))
      row.append(choose)
      if (this.canManage && this.managing) {
        const remove = document.createElement("button")
        remove.type = "button"
        remove.className = "shrink-0 px-2 py-1 text-red-700 underline"
        remove.textContent = this.manageTarget.dataset.deleteLabel
        remove.setAttribute("aria-label", `${this.manageTarget.dataset.deleteLabel}: ${prompt.title}`)
        remove.dataset.templateDelete = ""
        remove.addEventListener("click", () => this.destroyTemplate(prompt, index))
        row.append(remove)
      }
      this.listTarget.append(row)
    }
    if (!matches.length) this.listTarget.textContent = this.emptyValue
  }

  async save(event) {
    const button = event.currentTarget
    if (button.disabled) return
    button.disabled = true
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content },
        body: JSON.stringify({ meeting_id: this.meetingId, analysis_prompt: { title: this.titleTarget.value, prompt_text: this.field.value } })
      })
      if (!response.headers.get("content-type")?.includes("application/json")) throw new Error(this.errorValue)
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || this.errorValue)
      this.statusTarget.textContent = result.message
      this.titleBoxTarget.hidden = true
      await this.load()
    } catch (error) { this.statusTarget.textContent = error.message || this.errorValue }
    finally { button.disabled = false }
  }

  // `index` is the row's position in the list as rendered, which after the
  // reload is where the NEXT row stands.
  async destroyTemplate(prompt, index = 0) {
    if (!window.confirm(this.manageTarget.dataset.deleteConfirm.replace("__TITLE__", prompt.title))) return
    // Emptied first so the confirmation is a CHANGE of the live region even when
    // the previous delete left the very same sentence standing there.
    this.statusTarget.textContent = ""
    try {
      const response = await fetch(this.urlValue, {
        method: "DELETE",
        headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content },
        body: JSON.stringify({ meeting_id: this.meetingId, prompt_id: prompt.id })
      })
      if (!response.headers.get("content-type")?.includes("application/json")) throw new Error(this.errorValue)
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || this.errorValue)
      // ⚠️ A failed reload keeps the error it wrote: the list still shows the
      // deleted row, and "deleted" next to it would contradict what is on screen.
      // A reload skipped because another meeting took over still confirms the
      // delete -- it happened -- but moves no focus into a list it did not build.
      const reloaded = await this.load()
      if (!reloaded && this.statusTarget.textContent === this.errorValue) return
      if (reloaded) this.focusAfterDelete(index)
      // Announced AFTER the focus move, not before: the screen reader speaks the
      // newly focused control first and would cut a polite update written ahead
      // of it.
      this.statusTarget.textContent = result.message
    } catch (error) { this.statusTarget.textContent = error.message || this.errorValue }
  }

  // ⚠️ The reload rebuilds the list with replaceChildren, which removes the
  // delete button that held the focus and drops it on <body> -- a keyboard user
  // was thrown out of the picker after every delete and had to find the way
  // back in from the top of the page. So focus lands deliberately: on the next
  // row's delete button, and on the search field once no row follows.
  //
  // Only while it was lost with the row (or is still in the picker): during the
  // request the user may have moved on to the composer, and pulling focus out of
  // a field somebody is typing in is worse than the defect this fixes. Nor into
  // a picker that closed in the meantime.
  focusAfterDelete(index) {
    if (this.pickerTarget.hidden) return
    const active = document.activeElement
    if (active && active !== document.body && !this.pickerTarget.contains(active)) return
    const next = this.listTarget.querySelectorAll("button[data-template-delete]")[index]
    ;(next || this.searchTarget).focus()
  }
}
