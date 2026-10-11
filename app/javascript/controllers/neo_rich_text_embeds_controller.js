import { Controller } from "@hotwired/stimulus"
import { acceptsFile, parsePermittedTypes } from "rich_text_embed_accept"

// Courtesy check in front of Lexxy's upload (spike plan Inline-Bilder, E1 point 3).
// Listens to the cancelable `lexxy:file-accept` event on the editor, refuses NEW files
// that the server would refuse anyway (type from `data-image-types`, size from
// `data-max-bytes`, both rendered out of RichTextEmbeds) and says why. When the form
// carries an attachment field (`attachment` target), the refused file is handed to it
// instead of being dropped. The rule itself is RichTextEmbedGuard; this is UX only.
// Why not Lexxy's `permitted-attachment-types`: Lexxy applies it when loading stored
// content too and drops every attachment outside the list, existing PDF tiles included.
// This handler only ever sees files the user adds now.
export default class extends Controller {
  static targets = ["hint"]
  static values = { maxBytes: Number, maxMegabytes: Number, imageTypes: String, attachmentSelector: String }

  accept(event) {
    const file = event.detail?.file
    if (!file) return

    const limits = {
      types: parsePermittedTypes(this.imageTypesValue),
      maxBytes: this.maxBytesValue,
    }
    const verdict = acceptsFile(file, limits)
    if (verdict.accepted) return

    event.preventDefault()
    this.redirectToAttachmentField(file)
    this.showHint(verdict.reason, file)
  }

  // The file input lives next to the editor in the same form, not inside it, so it is
  // addressed by selector (rendered by RichTextEmbedsHelper) instead of a Stimulus target.
  get attachmentField() {
    if (!this.hasAttachmentSelectorValue) return null
    const form = this.element.closest("form")
    return form ? form.querySelector(this.attachmentSelectorValue) : null
  }

  redirectToAttachmentField(file) {
    const field = this.attachmentField
    if (!field) return
    try {
      const transfer = new DataTransfer()
      for (const existing of field.files || []) transfer.items.add(existing)
      transfer.items.add(file)
      field.files = transfer.files
      field.dispatchEvent(new Event("change", { bubbles: true }))
    } catch (_error) {
      // Browsers without DataTransfer file assignment: the hint alone has to do.
    }
  }

  showHint(reason, file) {
    const text = this.hintText(reason, file)
    if (!text) return

    const hint = this.hasHintTarget ? this.hintTarget : this.createHint()
    hint.textContent = text
    hint.hidden = false
    clearTimeout(this.hintTimer)
    this.hintTimer = setTimeout(() => { hint.hidden = true }, 8000)
  }

  // The base texts state the refusal ONLY; what to do next is the suffix, because it
  // depends on the form. With an attachment field the file is already there, so asking the
  // user to "upload it as an attachment" would ask for what just happened. Without one
  // (notes) only a size problem has a remedy the user can act on.
  hintText(reason, file) {
    const template = this.element.dataset[reason === "size" ? "hintTooLarge" : "hintNotImage"] || ""
    const suffix = this.attachmentField
      ? this.element.dataset.hintRedirected || ""
      : (reason === "size" ? this.element.dataset.hintShrink || "" : "")
    const text = template
      .replace("%{filename}", file.name || "")
      .replace("%{max}", String(this.maxMegabytesValue || ""))
    return `${text} ${suffix}`.trim()
  }

  createHint() {
    const hint = document.createElement("p")
    hint.className = "rich-text-embeds__hint"
    hint.setAttribute("role", "status")
    hint.dataset.neoRichTextEmbedsTarget = "hint"
    this.element.insertAdjacentElement("afterend", hint)
    return hint
  }

  disconnect() {
    clearTimeout(this.hintTimer)
  }
}
