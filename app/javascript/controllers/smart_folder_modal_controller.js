import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["closeButton"]

  connect() {
    this.body = document.querySelector('body');
    if (this.body) {
      this.body.style.overflow = 'hidden';
    }

    this.escKeyHandler = this.closeOnEsc.bind(this);
    document.addEventListener("keydown", this.escKeyHandler);
  }

  disconnect() {
    if (this.body) {
      this.body.style.overflow = '';
    }
    document.removeEventListener("keydown", this.escKeyHandler);
  }

  close() {
    this.element.remove();
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // The modal stands in the page only while it is open: Escape removes it.
  ownsEscape() {
    return true
  }

  closeOnEsc(event) {
    if (event.key === "Escape") {
      this.element.remove();
    }
  }

  closeBackground(event) {
    if (event.target === this.element) {
      this.element.remove();
    }
  }
}
