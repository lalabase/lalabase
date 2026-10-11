import { Controller } from "@hotwired/stimulus"

// Password field companion on the Werkstatt auth pages (design handoff 3a/3b):
// a text toggle that flips the input between password and text, and on the
// sign-up page a four-segment strength meter.
//
// The meter is INFORMATIVE only -- the binding rule stays server-side
// (Devise's password length validation). It never blocks submission. All
// user-facing strings arrive via values (i18n rule: no literals in JS).
export default class extends Controller {
  static targets = ["input", "toggle", "meter", "segment", "label"]
  static values = {
    showLabel: String,
    hideLabel: String,
    minLength: Number,
    // One label per score 1-4, e.g. ["Zu kurz", "Geht so", "Gut", "Stark"]
    strengthLabels: Array,
    // The server rule, e.g. "mindestens 12 Zeichen" -- shown next to the word
    rule: String,
  }

  toggle() {
    const hidden = this.inputTarget.type === "password"
    this.inputTarget.type = hidden ? "text" : "password"
    this.toggleTarget.setAttribute("aria-pressed", hidden ? "true" : "false")
    this.toggleTarget.textContent = hidden ? this.hideLabelValue : this.showLabelValue
    this.inputTarget.focus()
  }

  // Bound to input; shows nothing until the first character (handoff rule).
  rate() {
    if (!this.hasMeterTarget) return

    const value = this.inputTarget.value
    if (value.length === 0) {
      this.meterTarget.hidden = true
      return
    }

    this.meterTarget.hidden = false
    const score = this.score(value)

    this.segmentTargets.forEach((segment, index) => {
      segment.classList.toggle("lp-strength-on", index < score)
    })
    this.labelTarget.textContent = `${this.strengthLabelsValue[score - 1]} · ${this.ruleValue}`
  }

  // 1 = below the server minimum, 2 = long enough, 3/4 = long enough plus
  // character variety and extra length. Deliberately crude: a precise entropy
  // estimate would suggest an authority the meter does not have.
  score(value) {
    if (value.length < this.minLengthValue) return 1

    const variety = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/]
      .filter((pattern) => pattern.test(value)).length
    let score = 2
    if (variety >= 3) score += 1
    if (value.length >= this.minLengthValue + 4 && variety >= 2) score += 1
    return Math.min(score, 4)
  }
}
