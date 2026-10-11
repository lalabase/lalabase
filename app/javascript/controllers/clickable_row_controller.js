import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  connect() {
    this.element.style.cursor = "pointer"
  }

  click(event) {
    // Don't handle clicks on links, buttons or interactive elements
    if (event.target.closest('a') || event.target.closest('button') || 
        event.target.tagName === 'A' || event.target.tagName === 'BUTTON' ||
        event.target.closest('.dropdown') || event.target.closest('.no-click')) {
      return;
    }
    
    // Prevent default behavior
    event.preventDefault()
    
    // Determine which type of row this is
    const isDocument = this.element.hasAttribute('data-document-id');
    const isNote = this.element.hasAttribute('data-note-id');
    const isTicket = this.element.hasAttribute('data-ticket-id');
    
    if (isDocument || isNote || isTicket) {
      // Set the correct background class
      let bgClass = isDocument ? 'bg-blue-50' : 'bg-lime-100';
      
      // Remove highlight from all rows and add to the clicked one
      document.querySelectorAll('tr.bg-blue-50, tr.bg-lime-100').forEach(row => {
        row.classList.remove('bg-blue-50', 'bg-lime-100');
      });
      this.element.classList.add(bgClass);
      
      // Make content column visible
      const layout = document.getElementById('layout');
      if (layout && layout.classList.contains('hide-content')) {
        layout.classList.remove('hide-content');
      }
      
      // Find the right frame and set its src
      let frameId = 'document_display_frame'; // default
      if (isNote) frameId = 'note_display_frame';
      if (isTicket) frameId = 'ticket_display_frame';
      
      const frame = document.getElementById(frameId);
      if (frame) {
        const turboUrl = `${this.urlValue}?format=turbo_stream&frame=content`;
        frame.setAttribute('src', turboUrl);
      } else {
        // Direct navigation fallback
        window.location.href = this.urlValue;
      }
    } else {
      // Standard navigation for other rows
      window.location.href = this.urlValue;
    }
  }
}