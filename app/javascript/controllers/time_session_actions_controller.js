import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"
import { openEditModal, performDelete } from "time_session_modal"

// TimeSession Actions Controller
// Thin wrapper that delegates edit/delete to shared time_session_modal module
export default class extends Controller {

  editTimeSession(event) {
    event.preventDefault()
    event.stopPropagation()

    const { timeSessionId, projectId, ticketId } = event.currentTarget.dataset
    const context = event.currentTarget.dataset.context || 'ticket'

    const { cleanup } = openEditModal({ projectId, timeSessionId, ticketId, context })
    this.modalCleanup = cleanup
  }

  deleteTimeSession(event) {
    event.preventDefault()
    event.stopPropagation()

    const { timeSessionId, projectId } = event.currentTarget.dataset
    if (!I18n.confirm('stimulus.time_session_actions.confirm_delete')) return

    performDelete(projectId, timeSessionId).catch(() => {
      alert(I18n.t('stimulus.time_session_actions.delete_error'))
    })
  }

  disconnect() {
    this.modalCleanup?.()
  }
}
