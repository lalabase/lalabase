import { Controller } from "@hotwired/stimulus"

/**
 * Ticket Selector Controller
 *
 * Automatic pre-selection of the currently active ticket in forms.
 * This controller is a good example of a focused helper controller.
 *
 * PURPOSE:
 * - Finds the currently selected ticket in the UI
 * - Automatically pre-selects this ticket in a select field
 * - Improves the user experience through context-aware pre-selection
 *
 * HOW IT WORKS:
 * - Looks for the row with the class 'selected-row' (the open ticket)
 * - Reads the ticket-id from the data attribute
 * - Sets this ID as the value in the select field
 *
 * HTML STRUCTURE:
 * <form data-controller="ticket-selector">
 *   <select data-ticket-selector-target="ticketSelect">
 *     <option value="1">Ticket 1</option>
 *     <option value="2">Ticket 2</option>
 *   </select>
 * </form>
 *
 * PREREQUISITES:
 * - The open ticket carries the class 'selected-row'
 * - Active ticket must have data-ticket-id attribute
 * - Select field must be defined as ticketSelect target
 *
 * ADAPTING FOR OTHER PURPOSES:
 * 1. Rename the controller (e.g. project_selector_controller.js)
 * 2. Adjust the CSS class for the active element (line 47)
 * 3. Adjust the data attribute name (line 50)
 * 4. Adjust the target name
 */
export default class extends Controller {
  // Target: The select element in which the pre-selection is to be made
  static targets = ["ticketSelect"]

  connect() {
    // Set up MutationObserver to react to DOM changes
    this.setupMutationObserver()

    // Attempt the initial selection
    this.selectCurrentTicket()
  }

  disconnect() {
    // Clean up the observer when the controller disconnects
    if (this.observer) {
      this.observer.disconnect()
    }
  }
  
  /**
   * Sets up a MutationObserver that reacts to DOM changes
   * and retries the ticket selection whenever the DOM changes
   */
  setupMutationObserver() {
    // Only set up the observer if we have a ticketSelect target
    if (!this.hasTicketSelectTarget) {
      // No ticketSelect target found, skipping observer setup
      return
    }

    // Callback for DOM changes
    const observerCallback = (mutationsList) => {
      // Check whether relevant changes have occurred
      for (const mutation of mutationsList) {
        if (mutation.type === 'childList' || mutation.type === 'attributes') {
          // If the options in the select have changed, retry
          if (mutation.target === this.ticketSelectTarget ||
              this.ticketSelectTarget.contains(mutation.target)) {
            // Select options changed, retrying ticket selection
            this.selectCurrentTicket()
            break
          }

          // If the ticket selection has changed (class change)
          if (mutation.type === 'attributes' &&
              mutation.attributeName === 'class' &&
              mutation.target.tagName === 'TR' &&
              mutation.target.classList.contains('selected-row')) {
            // Ticket selection changed, retrying ticket selection
            this.selectCurrentTicket()
            break
          }
        }
      }
    }
    
    // Create the observer
    this.observer = new MutationObserver(observerCallback)

    // Configure and start the observer
    const config = {
      childList: true,    // Watches for adding/removing child nodes
      subtree: true,      // Also watches all descendant nodes
      attributes: true,   // Watches for attribute changes
      attributeFilter: ['class', 'data-ticket-id'] // Only relevant attributes
    }

    // Observe the select element and its container
    this.observer.observe(this.ticketSelectTarget, config)

    // Optional: also observe the container in case the select element is reloaded
    if (this.element !== this.ticketSelectTarget) {
      this.observer.observe(this.element, config)
    }

    // Also observe the ticket list to detect selection changes
    const ticketList = document.querySelector('#tickets-list')
    if (ticketList) {
      this.observer.observe(ticketList, config)
    }
  }
  
  /**
   * Pre-selects the currently active ticket in the select field
   *
   * Flow:
   * 1. Finds the active ticket element in the DOM
   * 2. Reads the ticket ID from the data attribute
   * 3. Sets this ID as the value in the select field
   * 4. Triggers a change event for other listeners
   */
  selectCurrentTicket() {
    if (!this.hasTicketSelectTarget) return

    // Find the currently selected ticket in the DOM
    const selectedRow = document.querySelector('tr.selected-row[data-ticket-id]')
    if (!selectedRow) return

    const ticketId = selectedRow.dataset.ticketId
    if (!ticketId) return

    // Only update if the value actually changes
    if (this.ticketSelectTarget.value === ticketId) return

    const optionExists = Array.from(this.ticketSelectTarget.options)
      .some(option => option.value === ticketId)

    if (optionExists) {
      this.ticketSelectTarget.value = ticketId
      this.ticketSelectTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
  }
}