import { Controller } from "@hotwired/stimulus"

// Frame navigation can change the address bar without updating Turbo's stored
// referrer. Account and management entry links need the current page, including
// its lane. Mount on a single link or a list of entry links.
export default class extends Controller {
  refresh(event) {
    const { url, fetchOptions } = event.detail
    const links = this.element.matches("a[href]") ? [this.element] : this.element.querySelectorAll("a[href]")
    if (fetchOptions.method === "GET" && Array.from(links).some((link) => url.href === link.href)) {
      fetchOptions.referrer = window.location.href
    }
  }
}
