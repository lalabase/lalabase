import { Controller } from "@hotwired/stimulus"

/**
 * Note Actions Controller
 * Ensures that the edit button works correctly after saving
 * and that all other actions are performed with the right note.
 */
export default class extends Controller {
  static values = {
    noteId: String
  }

  connect() {
    this.initializeEditButton();
  }

  /**
   * Initializes the edit button to ensure it works after saving
   */
  initializeEditButton() {
    const editButton = this.element.querySelector('a[href*="edit"]');
    if (editButton) {
      // Update the timestamp parameter to avoid cache issues
      let href = editButton.getAttribute('href');
      const timestamp = new Date().getTime();

      // Remove the existing timestamp, if present
      href = href.replace(/(_=\d+)/, '');

      // Determine how the new parameter should be inserted
      const separator = href.includes('?') ? '&' : '?';

      // Update the href with the new timestamp
      editButton.setAttribute('href', `${href}${separator}_=${timestamp}`);

      // Clone the button to remove all event listeners
      const newButton = editButton.cloneNode(true);
      if (editButton.parentNode) {
        editButton.parentNode.replaceChild(newButton, editButton);
      }
    }
  }

  /**
   * Must be called after every form submit
   * to update the edit button
   */
  refreshEditButton() {
    this.initializeEditButton();
  }
}
