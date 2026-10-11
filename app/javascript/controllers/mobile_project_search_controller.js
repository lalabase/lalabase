import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["project", "empty"]
  filter(event) {
    const query = event.target.value.trim().toLocaleLowerCase()
    this.projectTargets.forEach(row => { row.hidden = !row.dataset.name.toLocaleLowerCase().includes(query) })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.projectTargets.some(row => !row.hidden)
  }
}
