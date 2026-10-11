import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import I18n from "i18n"

/**
 * Turbo Cache Controller
 *
 * This controller prevents old detail views from being briefly displayed when
 * navigating back. The problem arises because Turbo caches the entire page
 * including all Turbo frames.
 *
 * The solution: clear all detail frames and clean up the URL state before caching.
 */
export default class extends Controller {
  connect() {
    // Bind methods once to ensure proper cleanup
    this.boundHandleBeforeCache = this.handleBeforeCache.bind(this);
    this.boundHandleBeforeRender = this.handleBeforeRender.bind(this);
    this.boundHandleVisit = this.handleVisit.bind(this);
    this.boundHandleBeforeVisit = this.handleBeforeVisit.bind(this);
    this.boundHandleLoad = this.handleLoad.bind(this);

    // Important events for caching
    document.addEventListener('turbo:before-cache', this.boundHandleBeforeCache);
    document.addEventListener('turbo:before-render', this.boundHandleBeforeRender);
    document.addEventListener('turbo:visit', this.boundHandleVisit);
    document.addEventListener('turbo:before-visit', this.boundHandleBeforeVisit);
    document.addEventListener('turbo:load', this.boundHandleLoad);

    // Initial cleanup if necessary
    this.cleanupOnLoad();
  }

  disconnect() {
    document.removeEventListener('turbo:before-cache', this.boundHandleBeforeCache);
    document.removeEventListener('turbo:before-render', this.boundHandleBeforeRender);
    document.removeEventListener('turbo:visit', this.boundHandleVisit);
    document.removeEventListener('turbo:before-visit', this.boundHandleBeforeVisit);
    document.removeEventListener('turbo:load', this.boundHandleLoad);
  }

  /**
   * Handle turbo:load event - runs after page is fully loaded
   */
  handleLoad(event) {
    // Only clean state on initial page load, not on frame updates
    const currentPath = window.location.pathname;
    const urlParams = new URLSearchParams(window.location.search);
    const isFrameUpdate = event.detail && event.detail.fetchResponse && event.detail.fetchResponse.response;

    // Skip cleaning if this is just a frame update
    if (isFrameUpdate) {
      return;
    }

    if (currentPath.includes('/tickets') && !urlParams.has('ticket_id') && !currentPath.match(/\/tickets\/[a-f0-9\-]+$/)) {
      // Only clean if we're really on the index page without a selected ticket
      const ticketFrame = document.getElementById('ticket_display_frame');
      if (ticketFrame) {
        const hasRealContent = ticketFrame.querySelector('.ticket-content');
        // Check if there's a selected ticket in the list
        const hasSelectedTicket = document.querySelector('.selected-row');

        if (hasRealContent && !hasSelectedTicket) {
          ticketFrame.innerHTML = `
            <div id="ticket-display" class="ticket-placeholder">
              <h1>${I18n.t('stimulus.turbo_cache.select_ticket')}</h1>
              <p>${I18n.t('stimulus.turbo_cache.ticket_content_hint')}</p>
            </div>
          `;
        }
      }

      // Clean layout
      const laborLayoutView = document.querySelector('.labor-layout-view');
      if (laborLayoutView && laborLayoutView.classList.contains('show-content')) {
        laborLayoutView.classList.remove('show-content');
      }

      const layout = document.querySelector('.layout');
      if (layout && layout.classList.contains('show-content')) {
        layout.classList.add('hide-content');
        layout.classList.remove('show-content');
      }

      // Clean highlights (.selected-row: the lane pages' mark since S2 of
      // doc/wissen_als_bahn_plan.md; this read tr.bg-lime-100 for a while
      // after #730 and found nothing)
      document.querySelectorAll('.selected-row').forEach(row => {
        row.classList.remove('selected-row');
      });
    }
  }

  /**
   * Called before Turbo caches the page
   * Here we must ensure that no detail content gets cached
   */
  handleBeforeCache(event) {
    const currentPath = window.location.pathname;
    const urlParams = new URLSearchParams(window.location.search);

    // ALWAYS clean ALL display frames to prevent any flicker
    const allDisplayFrames = document.querySelectorAll('turbo-frame[id$="_display_frame"]');
    allDisplayFrames.forEach(frame => {
      // Get appropriate placeholder based on frame ID
      const placeholderText = this.getPlaceholderTextForFrame(frame.id);

      // Replace content with placeholder
      if (frame.id === 'ticket_display_frame') {
        frame.innerHTML = `
          <div id="ticket-display" class="ticket-placeholder">
            <h1>${placeholderText}</h1>
            <p>${I18n.t('stimulus.turbo_cache.ticket_content_hint')}</p>
          </div>
        `;
      } else {
        frame.innerHTML = `
          <div class="flex justify-center items-center h-full p-8">
            <p class="text-gray-400">${placeholderText}</p>
          </div>
        `;
      }

      // Remove src attribute
      frame.removeAttribute('src');
    });

    // Always clean layout state on tickets page
    if (currentPath.includes('/tickets')) {
      // Clean layout classes
      const laborLayoutView = document.querySelector('.labor-layout-view');
      if (laborLayoutView) {
        laborLayoutView.classList.remove('show-content');
      }

      const layout = document.querySelector('.layout');
      if (layout) {
        layout.classList.add('hide-content');
        layout.classList.remove('show-content');
      }

      // Clean highlighted rows
      document.querySelectorAll('.selected-row').forEach(row => {
        row.classList.remove('selected-row');
      });

      // Reset URL if needed
      if (urlParams.get('page') && urlParams.get('page') !== '1') {
        urlParams.set('page', '1');
        urlParams.delete('ticket_id');
        const newUrl = `${currentPath}?${urlParams.toString()}`;
        window.history.replaceState({}, '', newUrl);
      }
    }

    // Close all modals
    const modals = document.querySelectorAll('[data-modal-target="modal"]:not(.hidden)');
    modals.forEach(modal => {
      modal.classList.add('hidden');
    });

    // Mark the document as having been cleaned for cache
    document.documentElement.setAttribute('data-turbo-cache-cleaned', 'true');
  }

  /**
   * Called before a new page is rendered
   */
  handleBeforeRender(event) {
    // If this is a preview (from cache), check if we need additional cleaning
    if (event.detail.isPreview) {
      const newBody = event.detail.newBody;

      // Check if this cached page was cleaned
      const wasCleaned = newBody.ownerDocument.documentElement.getAttribute('data-turbo-cache-cleaned') === 'true';

      // Additional safety: clean frames in the preview before rendering
      const previewFrames = newBody.querySelectorAll('turbo-frame[id$="_display_frame"]');
      previewFrames.forEach(frame => {
        // Check if frame has actual content (not placeholder)
        if (!frame.querySelector('.ticket-placeholder') &&
            !frame.querySelector('.text-gray-400')) {
          const placeholderText = this.getPlaceholderTextForFrame(frame.id);
          if (frame.id === 'ticket_display_frame') {
            frame.innerHTML = `
              <div id="ticket-display" class="ticket-placeholder">
                <h1>${placeholderText}</h1>
                <p>${I18n.t('stimulus.turbo_cache.ticket_content_hint')}</p>
              </div>
            `;
          } else {
            frame.innerHTML = `
              <div class="flex justify-center items-center h-full p-8">
                <p class="text-gray-400">${placeholderText}</p>
              </div>
            `;
          }
        }
      });
    }
  }

  /**
   * Called on every navigation
   */
  handleVisit(event) {
    // Navigation tracking (silent in production)
  }

  /**
   * Resets the layout state
   */
  resetLayoutState() {
    // Remove all highlight classes from rows
    document.querySelectorAll('.selected-row, tr.bg-lime-100, tr.bg-blue-50, tr.bg-yellow-100').forEach(row => {
      row.classList.remove('selected-row', 'bg-lime-100', 'bg-blue-50', 'bg-yellow-100');
    });

    // Reset layout elements
    const layoutElements = document.querySelectorAll('.layout');
    layoutElements.forEach(element => {
      // Hide content and panel lane
      element.classList.add('hide-content');
      element.classList.add('hide-panel');
    });

    // Remove labor-layout-view classes
    const laborLayoutViews = document.querySelectorAll('.labor-layout-view');
    laborLayoutViews.forEach(view => {
      view.classList.remove('show-content');
      view.classList.add('hide-panel');
    });

    // Clean up session storage
    const keysToRemove = ['smartfolder_navigation', 'notes_navigation_in_progress',
                          'tickets_navigation_in_progress', 'documents_navigation_in_progress'];
    keysToRemove.forEach(key => {
      sessionStorage.removeItem(key);
    });
  }

  /**
   * Removes detail IDs from the URL parameters
   */
  cleanUrlParams() {
    const url = new URL(window.location);
    const detailParams = ['ticket_id', 'note_id', 'document_id', 'time_session_id'];

    let changed = false;
    detailParams.forEach(param => {
      if (url.searchParams.has(param)) {
        url.searchParams.delete(param);
        changed = true;
      }
    });

    if (changed) {
      // Update the URL without a reload
      window.history.replaceState({}, '', url.toString());
    }
  }

  /**
   * Checks whether a URL is an index page
   */
  isIndexUrl(url) {
    const indexPaths = ['/tickets', '/notes', '/documents', '/time_sessions'];
    const urlObj = new URL(url, window.location.origin);
    return indexPaths.some(path => urlObj.pathname.endsWith(path));
  }

  /**
   * Checks whether a path is an index page
   */
  isIndexPage(path) {
    const indexPaths = ['/tickets', '/knowledge', '/time_sessions'];
    return indexPaths.some(indexPath => path.endsWith(indexPath));
  }

  /**
   * Returns the appropriate placeholder text for a frame
   */
  getPlaceholderTextForFrame(frameId) {
    const placeholderTexts = {
      'ticket_display_frame': I18n.t('stimulus.turbo_cache.select_ticket'),
      'knowledge_display_frame': I18n.t('stimulus.turbo_cache.select_entry'),
      'time_session_display_frame': I18n.t('stimulus.turbo_cache.select_time_session')
    };

    return placeholderTexts[frameId] || I18n.t('stimulus.turbo_cache.select_element');
  }

  /**
   * Runs on every page load to ensure that
   * no cached detail views are displayed
   */
  cleanupOnLoad() {
    // With aggressive cleaning, we don't need complex cleanup on load
  }

  /**
   * Called before a navigation
   */
  handleBeforeVisit(event) {
    // Pre-visit handling (silent in production)
  }

}
