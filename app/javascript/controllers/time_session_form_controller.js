import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["durationInput", "projectSelect", "ticketSelect", "ticketSelectContainer"]

  connect() {
    // On connection of the controller
    try {
      const contextField = this.element.querySelector('input[name="context"]');

      // Check for a hidden field for the index page context
      const sourceField = document.getElementById('time_sessions_source');
      if (sourceField && sourceField.value === 'index_page') {
        // If we are on the index page, set the context to index_page
        if (contextField) {
          contextField.value = 'index_page';
        }
        return;
      }

      if (contextField && !contextField.value) {
        // Try to get the context from the parent modal
        const modal = this.element.closest('[data-modal-target="modal"]');
        if (modal && modal.dataset.context) {
          contextField.value = modal.dataset.context;
        } else if (this.element.closest('[data-controller="modal"]')?.dataset.context) {
          // Alternatively try to get it from the modal controller
          contextField.value = this.element.closest('[data-controller="modal"]').dataset.context;
        } else {
          // Fallback for ticket view
          const ticketIdField = this.element.querySelector('input[name="time_session[ticket_id]"]');
          if (ticketIdField && ticketIdField.value) {
            contextField.value = 'ticket';
          }
        }
      }
    } catch (e) {
      console.warn("Error setting context field:", e);
    }
  }

  formatDuration() {
    try {
      // Check whether the target exists
      if (!this.hasDurationInputTarget) {
        console.warn("No duration input target found");
        return;
      }

      // This function only runs on input, not automatically on start
      const input = this.durationInputTarget;
      if (!input) {
        console.warn("Duration input element not found");
        return;
      }

      let value = input.value?.trim() || "";

      // Only format when the user is done typing and a valid format is present
      if (value && value.includes(':')) {
        const parts = value.split(':')
        if (parts.length === 2) {
          // Only format if both parts are numbers
          if (/^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
            const hours = parseInt(parts[0]) || 0
            const minutes = parseInt(parts[1]) || 0

            // Only format if the minutes are less than 60
            if (minutes < 60) {
              // Format minutes with a leading zero, leave hours unchanged
              input.value = `${hours}:${minutes.toString().padStart(2, '0')}`
            }
          }
        }
      }
    } catch (e) {
      console.warn("Error in formatDuration:", e);
    }
  }

  // Opens the native calendar on a click anywhere in the date field. Without
  // this, Safari only reacts to its tiny picker icon.
  openDatePicker(event) {
    const input = event.target;
    if (typeof input.showPicker !== "function") return;
    try {
      input.showPicker();
    } catch {
      // NotAllowedError outside a user gesture — the native behaviour remains.
    }
  }

  projectChanged(event) {
    const projectId = event.target.value;
    if (projectId) {
      // Fetch tickets for the selected project
      const url = `/org/${this.currentOrganisationId()}/time-tracking/tickets_for_project/${projectId}`;

      fetch(url, {
        method: 'GET',
        headers: {
          'Accept': 'text/vnd.turbo-stream.html',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        }
      })
      .then(response => response.text())
      .then(html => {
        // The turbo stream response will handle updating the ticket select
        Turbo.renderStreamMessage(html);
      })
      .catch(error => {
        console.error("Error fetching tickets:", error);
      });
    } else {
      // Reset ticket select if no project selected
      if (this.hasTicketSelectTarget) {
        this.ticketSelectTarget.innerHTML = `<select name="time_session[ticket_id]" class="block w-full rounded-lg border border-black px-3 py-2 focus:border-black focus:-translate-x-0.5 focus:-translate-y-0.5 focus:shadow-[2px_2px_0_0_#000000] focus:ring-0 transition-all duration-200 sm:text-sm bg-white" disabled><option value="">${I18n.t('stimulus.time_session_form.select_project_first')}</option></select>`;
      }
    }
  }

  currentOrganisationId() {
    // Extract organisation ID from the current URL or from a data attribute
    const match = window.location.pathname.match(/\/org\/([^\/]+)/);
    return match ? match[1] : null;
  }

  closeModal() {
    // Find the modal container
    const modalContainer = document.getElementById('time-session-modal-container');
    if (modalContainer && modalContainer.stimulusController) {
      modalContainer.stimulusController.close();
    } else {
      // Fallback: manually close the modal
      const modal = this.element.closest('[data-modal-target="modal"]');
      if (modal) {
        modal.classList.add('hidden');
        document.body.classList.remove('modal-open');
      }
    }

    // Remove highlight from rows
    document.querySelectorAll('tr.bg-lime-100').forEach(row => {
      row.classList.remove('bg-lime-100');
    });
  }

  handleSubmit(event) {
    try {
      if (event.detail && event.detail.success) {
        // Reset the form, if possible
        try {
          if (this.element && typeof this.element.reset === 'function') {
            this.element.reset();
          }

          if (this.hasDurationInputTarget) {
            this.formatDuration();
          }
        } catch (e) {
          console.warn("Could not reset form:", e);
        }

        // Determine the context and the source
        const contextField = this.element.querySelector('input[name="context"]');
        const sourceField = document.getElementById('time_sessions_source');

        // Check whether we are on the index page (highest priority)
        const isIndexPage = sourceField && sourceField.value === "index_page";
        const isIndexPageContext = contextField && contextField.value === 'index_page';

        // Or in the ticket context
        const isTicketContext = contextField && contextField.value === 'ticket';

        // Find the modal controller (if there is one)
        const modalController = this.element.closest('[data-controller="modal"]');
        if (modalController) {
          // Try to trigger the close action
          if (typeof modalController.dispatchEvent === 'function') {
            modalController.dispatchEvent(new CustomEvent('modal:close'));
          }
        }

        // Close all modal-controller modals
        document.querySelectorAll('[data-modal-target="modal"]').forEach(modalElement => {
          modalElement.classList.add('hidden');
        });

        // Remove TimeSession overlays, if present (from time_session_popup_controller)
        document.querySelectorAll('[id^="time-session-overlay-"]').forEach(overlay => {
          overlay.style.display = 'none';
          if (overlay.parentNode) {
            overlay.parentNode.removeChild(overlay);
          }
        });

        // Re-enable scrolling
        document.body.style.overflow = '';
        document.body.classList.remove('modal-open', 'overflow-hidden');
      }
    } catch (e) {
      console.error("Error in handleSubmit:", e);
    }
  }
}
