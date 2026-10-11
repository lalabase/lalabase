// Rails UJS is not needed with Turbo
// import * as Rails from "@rails/ujs"
// Rails.start()

// Import Turbo and Stimulus
import "@hotwired/turbo-rails"
import "@hotwired/stimulus"

// Import controllers
import "controllers"

// Debug: Check if Stimulus controllers are loaded
document.addEventListener('DOMContentLoaded', () => {
  const ticketRows = document.querySelectorAll('[data-controller="list-row"]');

  // Check if Stimulus is working
  if (window.Stimulus) {
    const app = window.Stimulus;
  } else {
    console.error('[STIMULUS] Stimulus is NOT loaded!');
  }
});

// Import Action Text (rendering helpers, direct upload) and Lexxy, THE rich text editor
// of the app since Paket 2 of the inline images (doc/inline_bilder_paket_2_plan.md); Trix
// is gone. Side-effect import: registers the <lexxy-editor> element.
import "@rails/actiontext"
import "lexxy"

// Function to automatically hide the alert
function autoDismissAlert(alert) {
  setTimeout(() => {
    if (alert && alert.parentNode) {
      alert.classList.remove('show');
      alert.classList.add('fade');
      setTimeout(() => {
        alert.remove();
      }, 150);
    }
  }, 2000);
}

// Function to initialize the auto-dismiss functionality for all alerts
function initializeAutoDismissAlerts() {
  const alerts = document.querySelectorAll('.alert');
  alerts.forEach(autoDismissAlert);
}

// Initialization after Turbo frame loads
document.addEventListener('turbo:frame-load', (event) => {
  // IMPORTANT: Prevent a full navigation from happening after a tickets_list_frame update
  if (event.target.id === 'tickets_list_frame') {
    // Stop any pending navigations
    if (window.Turbo && window.Turbo.navigator) {
      const navigator = window.Turbo.navigator;
      if (navigator.currentVisit) {
        navigator.currentVisit.cancel();
      }
    }

    // Prevent any automatic navigation that might be triggered
    event.stopImmediatePropagation();
  }
});

// Debug: Monitor frame src changes
const observer = new MutationObserver((mutations) => {
  mutations.forEach((mutation) => {
    if (mutation.type === 'attributes' && mutation.attributeName === 'src') {
      // Frame src change monitoring (silent in production)
    }
  });
});

// Observe all turbo frames
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('turbo-frame').forEach(frame => {
    observer.observe(frame, {
      attributes: true,
      attributeOldValue: true,
      attributeFilter: ['src']
    });
  });
});

Turbo.StreamActions.makeRowsClickable = function () {
  // No longer used - Stimulus controller handles clicks
};

// The board asks for its frame again from the page's live address
// (doc/kanban_ticket_als_bahn_plan.md, section 4.2): after "+ Ticket" the
// server closes the surface and sends this, instead of a board it would have
// to build without the page's filters, its search, its saved view and its
// open ticket. The address carries all of them; the frame request through
// index does too. An unchanged src does not fetch, so a frame that already
// stands at that address reloads instead.
Turbo.StreamActions.reloadFrame = function () {
  const frame = document.getElementById(this.target);
  if (!frame) return;
  const before = frame.getAttribute('src');
  frame.src = window.location.href;
  if (frame.getAttribute('src') === before) frame.reload();
};

// A record created inside a master/detail lane has no selection in the page
// address yet. The server supplies the canonical, filter-preserving index URL;
// replacing (not pushing) turns the current "new" state into the saved record
// without adding a dead form entry to Back/Forward history.
Turbo.StreamActions.replaceAddress = function () {
  const url = this.getAttribute('url');
  if (!url) return;
  window.history.replaceState({ lane: true }, '', url);
  // A list replacement and this custom action may connect in either order.
  // Re-mark all list rows after the canonical selection enters the address so
  // detail, highlight and subject-specific actions cannot disagree.
  document.dispatchEvent(new CustomEvent("lane:restored"));
};

// Stores the most recent Turbo requests in order to detect duplicates
const recentTurboRequests = new Map();

document.addEventListener("turbo:before-fetch-request", function(event) {
  const url = event.detail.url;
  const now = Date.now();

  // Catch undefined URLs early
  if (url && (url.toString().includes('undefined') || url.toString() === 'undefined')) {
    console.error('[TURBO] BLOCKING REQUEST TO UNDEFINED URL:', url);
    console.trace('Stack trace for undefined URL:');

    // Try to fix the URL if it's a tickets pagination request
    const urlString = url.toString();
    if (urlString.includes('/tickets/undefined')) {
      const fixedUrl = urlString.replace('/tickets/undefined', '/tickets');
      event.detail.url = new URL(fixedUrl, window.location.origin);
      // Don't prevent default, let it continue with the fixed URL
      return;
    }

    event.preventDefault();
    return;
  }

  // Make sure the items parameter is preserved on frame requests
  if (event.detail.fetchOptions.headers["Turbo-Frame"]) {
    const currentUrl = new URL(url, window.location.origin);
    const itemsFromSession = sessionStorage.getItem('items_per_page');

    // UUID pattern for detail URLs (e.g. /tickets/uuid)
    const uuidPattern = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const isDetailUrl = uuidPattern.test(currentUrl.pathname);

    // Only add the items parameter on list URLs, NOT on detail URLs
    if (!currentUrl.searchParams.has('items') && itemsFromSession && !isDetailUrl) {
      currentUrl.searchParams.set('items', itemsFromSession);
      // CRITICAL: event.detail.url MUST remain a URL object, NEVER use toString()!
      // Turbo expects a URL object. A string would lead to "/tickets/undefined" URLs.
      // See: https://github.com/hotwired/turbo/issues/...
      // BUG FIX from 12.08.2025: Pagination did not work from the detail view
      event.detail.url = currentUrl; // URL object
      // event.detail.url = currentUrl.toString(); // WRONG: would cause the bug!
    }
  }

  // Convert URL to string if it's a URL object
  const urlString = url instanceof URL ? url.toString() : url;

  // Try to detect and block duplicate requests within a short time window.
  // A duplicate is the SAME request: same address, same method, same target
  // frame. Keyed on the address alone, the board's reload GET of its frame
  // after a fast "+ Ticket" POST to the same index address was swallowed
  // inside the 500ms, and the surface closed on an unchanged board
  // (doc/kanban_ticket_als_bahn_plan.md, section 4.2).
  if (urlString && (urlString.includes('/notes') || urlString.includes('/tickets') || urlString.includes('/documents') || urlString.includes('/time_sessions')) && !urlString.includes('frame=content')) {
    const method = String(event.detail.fetchOptions.method || 'GET').toUpperCase();
    const targetFrame = event.detail.fetchOptions.headers['Turbo-Frame'] || '';
    const requestKey = `${method} ${targetFrame} ${urlString}`;
    const lastRequest = recentTurboRequests.get(requestKey);
    if (lastRequest && (now - lastRequest) < 500) {
      event.preventDefault();
      return;
    }

    // Store the timestamp of this request
    recentTurboRequests.set(requestKey, now);

    // Delete old entries after 2 seconds
    setTimeout(() => {
      recentTurboRequests.delete(requestKey);
    }, 2000);
  }
});
