import { Controller } from "@hotwired/stimulus"

// Copy buttons for code blocks in the in-app help (/hilfe).
//
// The buttons live inside CACHED docs-engine HTML (.docs-codeblock__copy) and
// therefore carry no Stimulus attributes or locale-specific labels of their
// own — one controller on the prose container labels them on connect and
// handles clicks via delegation. Deliberately separate from
// clipboard_controller.js, which expects a source input + button targets in
// author-controlled markup.
//
// Usage:
//   <div data-controller="help-copy"
//        data-action="click->help-copy#copy"
//        data-help-copy-copy-label-value="<%= t('...') %>"
//        data-help-copy-copied-label-value="<%= t('...') %>">
//     ...cached body_html with .docs-codeblock__copy buttons...
//   </div>
export default class extends Controller {
  static values = {
    copyLabel: { type: String, default: "Copy" },
    copiedLabel: { type: String, default: "Copied" },
    resetMs: { type: Number, default: 1500 },
  }

  connect() {
    this.element.querySelectorAll(".docs-codeblock__copy").forEach((button) => {
      if (!button.textContent.trim()) button.textContent = this.copyLabelValue
      // Request locale wins over the aria-label baked in the page locale
      // (relevant on the EN→DE content fallback).
      button.setAttribute("aria-label", this.copyLabelValue)
    })
  }

  copy(event) {
    const button = event.target.closest(".docs-codeblock__copy")
    if (!button) return

    const pre = button.closest(".docs-codeblock")?.querySelector("pre")
    if (!pre) return

    navigator.clipboard.writeText(pre.innerText).then(() => this.#flash(button))
  }

  #flash(button) {
    button.textContent = this.copiedLabelValue
    button.setAttribute("aria-label", this.copiedLabelValue)
    button.classList.add("is-copied")

    clearTimeout(this._timer)
    this._timer = setTimeout(() => {
      button.textContent = this.copyLabelValue
      button.setAttribute("aria-label", this.copyLabelValue)
      button.classList.remove("is-copied")
    }, this.resetMsValue)
  }
}
