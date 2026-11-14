import { Controller } from "@hotwired/stimulus"
import { listActionAddress } from "inbox_live"

// The head of the lane on the inbox above the organisations ("Als gelesen",
// "Archivieren", "Zurück in die Inbox"). Its answer redraws the list, so its
// form takes the list state the page's address names when it leaves, and the
// pages the endless scroll has loaded, as the bulk bar does: a search typed
// after the lane opened must survive the action. The open row stays the one
// the form names (a search drops it from the page's address); the answer swaps
// the head for it.
export default class extends Controller {
  carry(event) {
    const form = event.target
    if (!form?.action) return
    form.action = listActionAddress(window.location.href, form.action, document.getElementById("inbox_master_list"),
                                    { keep: ["notification"] })
  }
}
