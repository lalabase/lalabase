import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["modal"]

  connect() {
    // Store a reference to the Stimulus instance for external access
    this.element.stimulusController = this;

    // Determine the modal type based on data-modal-type or ID
    this.modalType = this.element.dataset.modalType || this.determineModalType();

    // Find the modal via the data-modal-target
    this.modalElement = this.element.querySelector('[data-modal-target="modal"]')

    if (!this.modalElement) {
      console.warn("Modalfenster konnte nicht mit data-modal-target gefunden werden")
      this.modalElement = this.element.querySelector('.modal')
    }

    if (!this.modalElement) {
      console.error("Kein Modalfenster Element gefunden")
    }

    // Initialize the modal as closed
    this.close()

    // Project contexts
    this.projectId = this.element.dataset.projectId;
  }

  determineModalType() {
    // Determine modal type based on container ID or other attributes
    const elementId = this.element.id;

    if (elementId.includes('time-session')) return 'timeSession';
    if (elementId.includes('ticket')) return 'ticket';
    if (elementId.includes('smart-folder')) return 'smartFolder';

    // Fallback: look for form containers
    if (this.element.querySelector('#time_session_form_container')) return 'timeSession';
    if (this.element.querySelector('#ticket_form_container')) return 'ticket';
    if (this.element.querySelector('#smart_folder_form_container')) return 'smartFolder';

    return 'generic';
  }

  storeOriginalContent() {
    // This method is no longer needed for TimeSession modal
    // as we're using Turbo Frame reload instead
    switch(this.modalType) {
      case 'timeSession':
        // Skip storing for TimeSession - we'll reload the frame instead
        break;

      case 'ticket':
        const ticketFormContainer = this.modalElement?.querySelector('#ticket_form_container');
        if (ticketFormContainer?.innerHTML) {
          this.originalFormHTML = ticketFormContainer.innerHTML;
        }
        break;

      case 'smartFolder':
        const smartFolderFormContainer = this.modalElement?.querySelector('#smart_folder_form_container');
        if (smartFolderFormContainer?.innerHTML) {
          this.originalFormHTML = smartFolderFormContainer.innerHTML;
        }
        break;
    }
  }

  open(event) {
    if (!this.modalElement) {
      console.error("Kann Modal nicht öffnen: Kein Modal-Element gefunden")
      return
    }

    // Show the modal
    this.modalElement.classList.remove("hidden")
    document.body.classList.add("modal-open")

    // Clean up any existing errors before opening
    this.cleanupErrors();

    // Handle modal-specific logic
    switch(this.modalType) {
      case 'timeSession':
        this.openTimeSessionModal(event);
        break;
      case 'ticket':
        this.openTicketModal(event);
        break;
      case 'smartFolder':
        this.openSmartFolderModal(event);
        break;
    }
  }

  cleanupErrors() {
    // Remove all error containers with the specific class
    const errorContainers = this.modalElement.querySelectorAll('.time-session-error-container');
    errorContainers.forEach(container => {
      container.remove();
    });

    // Also look for any bg-red-50 divs (error styling)
    const errorDivs = this.modalElement.querySelectorAll('.bg-red-50');
    errorDivs.forEach(div => {
      div.remove();
    });

    // Reset form fields for TimeSession modal
    if (this.modalType === 'timeSession') {
      const form = this.modalElement.querySelector('form#time_session_form');
      if (form) {
        // Reset form
        form.reset();

        // Reset date to today
        const dateInput = form.querySelector('input[type="date"]');
        if (dateInput) {
          dateInput.value = new Date().toISOString().split('T')[0];
        }

        // Clear all text inputs and textareas
        form.querySelectorAll('input[type="text"], textarea').forEach(field => {
          field.value = '';
        });

        // Reset all selects
        form.querySelectorAll('select').forEach(select => {
          select.selectedIndex = 0;
        });
      }
    }
  }

  openTimeSessionModal(event) {
    // TimeSession-specific logic
    if (event?.currentTarget?.dataset) {
      this.timeSessionId = event.currentTarget.dataset.timeSessionId;
      this.ticketId = event.currentTarget.dataset.ticketId;
      this.context = event.currentTarget.dataset.context;
    }

    // When it is an edit
    if (this.timeSessionId && this.timeSessionId !== 'undefined') {
      this.loadTimeSessionEditForm();
    }
  }

  openTicketModal(event) {
    // Ticket-specific logic
    if (event?.currentTarget?.dataset) {
      this.ticketId = event.currentTarget.dataset.ticketId;
    }

    // Set the title for a new ticket
    const modalTitle = this.modalElement.querySelector('h3');
    if (modalTitle && !this.ticketId) {
      modalTitle.textContent = I18n.t('stimulus.modal.new_ticket');
    }
  }

  openSmartFolderModal(event) {
    // SmartFolder-specific logic
    if (event?.currentTarget?.dataset) {
      this.smartFolderId = event.currentTarget.dataset.smartFolderId;
    }
  }

  loadTimeSessionEditForm() {
    const projectId = this.element.dataset.projectId || this.projectId;
    const formContainer = document.getElementById('time_session_form_container');

    if (!formContainer) {
      console.error("Missing formContainer for TimeSession edit");
      return;
    }

    // Update modal title
    const modalTitle = this.modalElement.querySelector('h3');
    if (modalTitle) {
      modalTitle.textContent = I18n.t('stimulus.modal.edit_time_session');
    }

    // Get organisation ID from URL
    const orgMatch = window.location.pathname.match(/\/org\/([^\/]+)/);
    const orgId = orgMatch ? orgMatch[1] : null;

    if (!orgId) {
      console.error("Organisation ID not found in URL");
      return;
    }

    // Determine if we're in project context or organization-wide context
    const isProjectContext = window.location.pathname.includes('/projects/');
    let url;

    if (isProjectContext && projectId) {
      // Project-specific context
      url = `/org/${orgId}/projects/${projectId}/time_sessions/${this.timeSessionId}/edit`;
    } else {
      // Organization-wide context
      url = `/org/${orgId}/time-tracking/${this.timeSessionId}/edit`;
    }

    if (this.ticketId) {
      url += `?ticket_id=${this.ticketId}`;
    }

    // Use Turbo Frame to load the edit form
    const formFrame = document.getElementById('time_session_form_frame');
    if (formFrame) {
      formFrame.src = url;
    } else {
      // Fallback: Load directly into the form container
      fetch(url, {
        headers: {
          'Accept': 'text/html',
          'Turbo-Frame': 'time_session_form_frame'
        }
      })
      .then(response => {
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.text();
      })
      .then(html => {
        formContainer.innerHTML = html;
      })
      .catch(error => {
        console.error('Error loading edit form:', error);
        alert(I18n.t('stimulus.modal.form_load_error', {error: error.message}));
      });
    }
  }

  close() {
    if (!this.modalElement) {
      return;
    }

    this.modalElement.classList.add("hidden")
    document.body.classList.remove("modal-open")

    // Handle modal-specific cleanup
    switch(this.modalType) {
      case 'timeSession':
        this.closeTimeSessionModal();
        break;
      case 'ticket':
        this.closeTicketModal();
        break;
      case 'smartFolder':
        this.closeSmartFolderModal();
        break;
    }

    // Clear common data
    this.timeSessionId = null;
    this.ticketId = null;
    this.smartFolderId = null;
  }

  closeTimeSessionModal() {
    // Reset title
    const modalTitle = this.modalElement.querySelector('h3');
    if (modalTitle) {
      modalTitle.textContent = 'Neue Zeitsession';
    }

    // Remove row highlights
    document.querySelectorAll('tr.bg-lime-100').forEach(row => {
      row.classList.remove('bg-lime-100');
    });

    // Clear the time session ID to ensure next open is for new session
    this.timeSessionId = null;

    // Clean up errors from the modal
    this.cleanupErrors();
  }

  closeTicketModal() {
    // Reset title
    const modalTitle = this.modalElement.querySelector('h3');
    if (modalTitle) {
      modalTitle.textContent = 'Neues Ticket';
    }

    // Restore original form
    const container = this.modalElement.querySelector('#ticket_form_container');
    if (container && this.originalFormHTML) {
      container.innerHTML = this.originalFormHTML;

      // SlimSelect re-initialization is handled automatically by Stimulus
      // when the DOM is updated (slim-select controller reconnects)
    }
  }

  closeSmartFolderModal() {
    // Restore original form
    const container = this.modalElement.querySelector('#smart_folder_form_container');
    if (container && this.originalFormHTML) {
      container.innerHTML = this.originalFormHTML;
    }
  }

  // Close the modal on click outside
  clickOutside(event) {
    if (!this.modalElement) {
      return;
    }

    const modalContent = this.modalElement.querySelector('.bg-white')
    if (modalContent && !modalContent.contains(event.target)) {
      this.close()
    }
  }
}
