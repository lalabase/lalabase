import { Controller } from "@hotwired/stimulus"
import { titleFromFilename, mayPrefill } from "upload_zone/title"

// The drop zone of the document forms (S4 of doc/dokumentansicht_plan.md, the
// designer's 43a): the file first. The zone is a LABEL around the real file
// input (documents/_upload_zone), so a click opens the picker by itself and
// the input stays the field the form submits; this adds only what a label
// cannot: drag and drop, the chosen file's name, the title suggestion and the
// button's off state. It sits on the FORM, because the title field and the
// button live outside the zone.
export default class extends Controller {
  static targets = ["input", "zone", "name", "title", "submit"]
  static values = { emptyLabel: String }
  static classes = ["over"]

  connect() {
    this.lastSuggestion = ""
    this.sync()
  }

  over(event) {
    event.preventDefault()
    this.zoneTarget.classList.add(...this.overClasses)
  }

  leave() {
    this.zoneTarget.classList.remove(...this.overClasses)
  }

  drop(event) {
    event.preventDefault()
    this.leave()
    const dropped = event.dataTransfer && event.dataTransfer.files
    if (!dropped || dropped.length === 0) return
    // One file is shown, so one file is sent: the input takes the FIRST alone.
    // A FileList assigned whole keeps every dropped file, multiple: false or
    // not, the form then repeats the parameter and the server keeps the last,
    // a different file from the one the zone named (review of #784).
    const single = new DataTransfer()
    single.items.add(dropped[0])
    this.inputTarget.files = single.files
    this.sync()
  }

  changed() {
    this.sync()
  }

  // The one place that reads the input: the name, the title, the button.
  sync() {
    const file = this.inputTarget.files && this.inputTarget.files[0]
    if (this.hasNameTarget) this.nameTarget.textContent = file ? file.name : this.emptyLabelValue
    if (this.hasTitleTarget && file) {
      const suggestion = titleFromFilename(file.name)
      if (mayPrefill(this.titleTarget.value, this.lastSuggestion)) this.titleTarget.value = suggestion
      this.lastSuggestion = suggestion
    }
    if (this.hasSubmitTarget) this.submitTarget.disabled = !file
  }
}
