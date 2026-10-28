// The additional details of a person in the people form (PersonDetail): add a
// row from the template, remove one, and switch the value field and the label
// suggestions when the kind changes. The kinds, their inputs and the limit come
// from the server as values; nothing here names a kind.
//
// Without JavaScript the stored rows still render and save; the add button
// stays hidden, because only adding needs this controller.
import { Controller } from "@hotwired/stimulus"
import { nextIndex, fillIndex, canAdd, valueField, singleLine } from "person_details"

export default class extends Controller {
  static targets = ["list", "row", "template", "add", "limit"]
  static values = { max: Number, kinds: Object, positionLabel: String }

  connect() {
    this.update()
  }

  add(event) {
    event.preventDefault()
    if (!canAdd(this.rowTargets.length, this.maxValue)) return

    const index = nextIndex(this.rowTargets.map((row) => row.dataset.index))
    this.listTarget.insertAdjacentHTML("beforeend", fillIndex(this.templateTarget.innerHTML, index))
    this.update()
    this.rowTargets[this.rowTargets.length - 1]?.querySelector("select")?.focus()
  }

  remove(event) {
    event.preventDefault()
    const row = this.rowTargets.find((candidate) => candidate.contains(event.currentTarget))
    if (!row) return

    row.remove()
    this.update()
    if (this.addTarget.hidden) return
    this.addTarget.focus()
  }

  changeKind(event) {
    const row = this.rowTargets.find((candidate) => candidate.contains(event.currentTarget))
    if (!row) return

    const field = valueField(this.kindsValue, event.currentTarget.value)
    const label = row.querySelector("[data-person-details-label]")
    if (label && field.list) label.setAttribute("list", field.list)
    else label?.removeAttribute("list")

    const current = row.querySelector("[data-person-details-value]")
    if (!current) return
    const value = field.tag === "textarea" ? current.value : singleLine(current.value)
    const next = current.tagName.toLowerCase() === field.tag ? current : this.rebuild(current, field.tag)
    if (field.type) next.type = field.type
    next.value = value
    // A field that cannot hold the value empties it (a date field and
    // "im Mai"). The row keeps a text field with the value instead, and the
    // server names the problem on save; nothing is lost behind a success.
    if (value !== "" && next.value === "") {
      next.type = "text"
      next.value = value
    }
    if (field.maxlength) next.maxLength = field.maxlength
  }

  // A textarea for an input or the other way round, with the same name, value
  // and wiring.
  rebuild(current, tag) {
    const next = document.createElement(tag)
    for (const attribute of current.attributes) {
      if (!["type", "rows", "value"].includes(attribute.name)) next.setAttribute(attribute.name, attribute.value)
    }
    next.classList.toggle("people-input--area", tag === "textarea")
    if (tag === "textarea") next.rows = 3
    next.value = current.value
    current.replaceWith(next)
    return next
  }

  update() {
    this.rowTargets.forEach((row, index) => {
      row.setAttribute("aria-label", this.positionLabelValue.replace("%{position}", String(index + 1)))
    })
    const room = canAdd(this.rowTargets.length, this.maxValue)
    this.addTarget.hidden = !room
    this.limitTarget.hidden = room
  }
}
