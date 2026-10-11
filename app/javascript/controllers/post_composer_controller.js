import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Ticket comment composer (T5, doc/tickets_detail_entschlackt_plan.md).
//
// Dresses the UNCHANGED form fields as footer words and chips: "Format"
// toggles the Lexxy toolbar (hidden by default, components/post_composer.css),
// "Datei" is a native label around the hidden multi file input (only the
// chosen-count text comes from here), "Status aendern" reveals the
// ticket_status select (posts_controller#handle_ticket_status_change has
// consumed that param forever), and the private checkbox drives the hint
// line, the darker card frame and the submit label swap. No form logic here.
export default class extends Controller {
  static targets = [
    "card", "fileInput", "fileCount", "statusWrap",
    "privateHint", "sendLabel", "sendPrivateLabel"
  ]

  toggleFormat(event) {
    const open = this.cardTarget.classList.toggle("post-composer--format-open")
    event.currentTarget.setAttribute("aria-pressed", open ? "true" : "false")
  }

  fileChanged() {
    if (!this.hasFileCountTarget) return

    const count = this.fileInputTarget.files.length
    this.fileCountTarget.textContent =
      count > 0 ? I18n.t("stimulus.post_composer.files_selected", { count: count }) : ""
    this.fileCountTarget.classList.toggle("hidden", count === 0)
  }

  toggleStatus(event) {
    const wrap = this.statusWrapTarget
    const open = !wrap.classList.toggle("hidden")
    event.currentTarget.setAttribute("aria-pressed", open ? "true" : "false")
    // Closing the picker withdraws the choice - a hidden select must not
    // silently change the ticket status on submit.
    if (!open) {
      const select = wrap.querySelector("select")
      if (select) select.value = ""
    }
  }

  privateChanged(event) {
    const on = event.target.checked
    if (this.hasPrivateHintTarget) this.privateHintTarget.classList.toggle("hidden", !on)
    if (this.hasSendLabelTarget) this.sendLabelTarget.classList.toggle("hidden", on)
    if (this.hasSendPrivateLabelTarget) this.sendPrivateLabelTarget.classList.toggle("hidden", !on)
    // Inline style, not a class toggle: deterministic against utility order.
    this.cardTarget.style.borderColor = on ? "#23221e" : ""
  }
}
