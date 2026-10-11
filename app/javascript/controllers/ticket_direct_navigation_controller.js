import { Controller } from "@hotwired/stimulus"

// This controller handles direct navigation to ticket pages
// It ensures the ticket content is properly displayed when accessing a ticket URL directly
export default class extends Controller {
  connect() {
    // Check if we're on a ticket detail page (URL contains /tickets/{id})
    const ticketMatch = window.location.pathname.match(/\/tickets\/([a-f0-9\-]+)$/)

    if (ticketMatch && ticketMatch[1]) {
      const ticketId = ticketMatch[1]

      // Check if the ticket content is already loaded
      const ticketDisplayFrame = document.getElementById('ticket_display_frame')
      const ticketContent = ticketDisplayFrame?.querySelector('#ticket-header')

      if (!ticketContent) {
        // Find the ticket row and trigger its click to load the content
        const ticketRow = document.querySelector(`tr[data-ticket-id="${ticketId}"]`)
        if (ticketRow) {
          const ticketRowController = this.application.getControllerForElementAndIdentifier(
            ticketRow,
            'list-row'
          )
          if (ticketRowController) {
            const event = new MouseEvent('click', {
              bubbles: true,
              cancelable: true,
              view: window
            })
            ticketRowController.click(event)
          }
        }
      }

      // Ensure the correct ticket row is highlighted
      this.highlightTicketRow(ticketId)
    }
  }

  // Since #730 the server marks the row of a deep link itself and
  // list_row_controller re-marks from the address on connect; this is a
  // second writer of the same mark and a candidate for deletion.
  highlightTicketRow(ticketId) {
    document.querySelectorAll('.selected-row').forEach(row => row.classList.remove('selected-row'))

    const ticketRow = document.querySelector(`tr[data-ticket-id="${ticketId}"]`)
    if (ticketRow) ticketRow.classList.add('selected-row')
  }
}
