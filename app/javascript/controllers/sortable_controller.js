import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = ["handle"]
  static values = {
    animation: Number,
    updateUrl: String
  }

  connect() {
    const options = {
      animation: this.animationValue || 150,
      ghostClass: 'sortable-ghost',
      chosenClass: 'sortable-chosen',
      dragClass: 'sortable-drag',
      onEnd: this.end.bind(this)
    }

    if (this.hasHandleTarget) {
      options.handle = "[data-sortable-target='handle']"
    }

    this.sortable = Sortable.create(this.element, options)
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }

  end(event) {
    if (!this.hasUpdateUrlValue || this.updateUrlValue === "#") {
      const items = Array.from(event.to.children).map(item => item.getAttribute('data-id'))
      this.dispatch("end", { detail: { order: items } })
      return
    }

    if (this.updateUrlValue.includes('/sort')) {
      const items = Array.from(event.to.children).map(item => item.getAttribute('data-id'))

      let dataKey = 'ids'
      if (this.updateUrlValue.includes('ticket_status')) {
        dataKey = 'ticket_status'
      } else if (this.updateUrlValue.includes('ticket_priorities')) {
        dataKey = 'ticket_priority'
      }

      fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
        },
        body: JSON.stringify({ [dataKey]: items })
      })
    } else {
      const itemId = event.item.dataset.id
      const position = event.newIndex

      if (itemId) {
        const formData = new FormData()
        formData.append("position", position)

        fetch(this.updateUrlValue.replace(":id", itemId), {
          method: "PATCH",
          headers: {
            "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
          },
          body: formData
        })
      }
    }
  }
}
