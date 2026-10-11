import { Controller } from "@hotwired/stimulus"
import SlimSelect from "slim-select"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["select"]

  connect() {
    this.initSlimSelect()
  }

  disconnect() {
    if (this.slimInstance) {
      this.slimInstance.destroy()
      this.slimInstance = null
    }
  }

  initSlimSelect() {
    const selectEl = this.selectTarget

    if (selectEl.slim) {
      selectEl.slim.destroy()
    }

    try {
      this.slimInstance = new SlimSelect({
        select: selectEl,
        settings: {
          placeholderText: I18n.t('stimulus.slim_select.select_user_placeholder'),
          allowDeselect: true,
          closeOnSelect: false
        }
      })
      selectEl.slim = this.slimInstance
    } catch (error) {
      console.error("Error initializing SlimSelect:", error)
    }
  }
}
