import { Controller } from "@hotwired/stimulus"

/**
 * Keyboard Navigation Controller
 *
 * Enables keyboard navigation in lists (Tab/Arrow/Enter)
 */
export default class extends Controller {
  static targets = ["searchInput", "listContainer", "row"]
  
  connect() {
    this.currentIndex = -1;
    
    // Bind methods once for proper cleanup
    this.boundHandleSearchKeydown = this.handleSearchKeydown.bind(this);
    this.boundHandleListKeydown = this.handleListKeydown.bind(this);
    this.boundHandleGlobalKeydown = this.handleGlobalKeydown.bind(this);
    this.boundHandleFrameLoad = this.handleFrameLoad.bind(this);
    
    // Event listeners for keyboard input
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.addEventListener('keydown', this.boundHandleSearchKeydown);
    }
    
    // Global keydown listener for the navigation
    document.addEventListener('keydown', this.boundHandleGlobalKeydown);
    
    // Listen for turbo frame loads to handle dynamic content
    document.addEventListener('turbo:frame-load', this.boundHandleFrameLoad);
  }
  
  disconnect() {
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.removeEventListener('keydown', this.boundHandleSearchKeydown);
    }
    document.removeEventListener('keydown', this.boundHandleGlobalKeydown);
    document.removeEventListener('turbo:frame-load', this.boundHandleFrameLoad);
  }
  
  handleFrameLoad(event) {
    // Check if the loaded frame is inside our list container
    if (this.hasListContainerTarget && this.listContainerTarget.contains(event.target)) {
      // Reset the current index since content has changed
      this.currentIndex = -1;
    }
  }
  
  handleGlobalKeydown(event) {
    // Check whether we are in the list
    const activeElement = document.activeElement;
    const rowSelectors = [
      'tr[data-controller*="list-row"]',
      'tr[data-controller*="time-session-row"]'
    ];
    
    const isInList = activeElement && rowSelectors.some(selector => activeElement.closest(selector));
    
    if (isInList) {
      this.handleListKeydown(event);
    }
  }
  
  handleSearchKeydown(event) {
    // Arrow-down enters the rows. Tab keeps the browser's normal form order so
    // filters following the search field remain keyboard-reachable.
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.focusFirstRow();
    }
  }
  
  handleListKeydown(event) {
    // Check whether the event comes from a row
    const rowSelectors = [
      'tr[data-controller*="list-row"]',
      'tr[data-controller*="time-session-row"]'
    ];
    
    const targetRow = rowSelectors.reduce((found, selector) => {
      return found || event.target.closest(selector);
    }, null);
    
    if (!targetRow) return;
    
    const rows = this.getNavigableRows();
    if (rows.length === 0) return;
    
    switch(event.key) {
      case 'ArrowDown':
        event.preventDefault();
        this.navigateDown(rows);
        break;
        
      case 'ArrowUp':
        event.preventDefault();
        this.navigateUp(rows);
        break;
        
      case 'Enter':
        event.preventDefault();
        this.selectCurrentRow(rows);
        break;
        
      case 'Escape':
        event.preventDefault();
        this.returnToSearch();
        break;
    }
  }
  
  getNavigableRows() {
    if (!this.hasListContainerTarget) return [];

    // Find all navigable rows (ticket-row, knowledge-row, time-session-row)
    const selectors = [
      'tr[data-controller*="list-row"]',
      'tr[data-controller*="time-session-row"]'
    ];
    
    const selector = selectors.join(', ');
    const rows = Array.from(this.listContainerTarget.querySelectorAll(selector));
    
    // Debug: if no rows found, check what's in the container
    if (rows.length === 0) {
      // No navigable rows found in container
    }
    
    return rows;
  }
  
  focusFirstRow() {
    const rows = this.getNavigableRows();
    
    if (rows.length > 0) {
      this.currentIndex = 0;
      this.highlightRow(rows[0]);
      rows[0].setAttribute('tabindex', '0');
      rows[0].focus();
      
      // Scroll into view if needed
      rows[0].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }
  
  navigateDown(rows) {
    if (this.currentIndex < rows.length - 1) {
      // Remove highlight from the current element
      if (this.currentIndex >= 0) {
        this.removeHighlight(rows[this.currentIndex]);
      }
      
      this.currentIndex++;
      this.highlightRow(rows[this.currentIndex]);
      rows[this.currentIndex].focus();
      
      // Scroll into view
      rows[this.currentIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }
  
  navigateUp(rows) {
    if (this.currentIndex > 0) {
      // Remove highlight from the current element
      this.removeHighlight(rows[this.currentIndex]);
      
      this.currentIndex--;
      this.highlightRow(rows[this.currentIndex]);
      rows[this.currentIndex].focus();
      
      // Scroll into view
      rows[this.currentIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    } else if (this.currentIndex === 0) {
      // Back to the search field
      this.removeHighlight(rows[0]);
      this.currentIndex = -1;
      this.returnToSearch();
    }
  }
  
  highlightRow(row) {
    // Check whether the row is already selected (green background)
    const isSelected = row.classList.contains('selected-row');
    
    if (isSelected) {
      // Selected row gets a darker green
      row.classList.add('bg-lime-200');
    } else {
      // Normal row gets a gray hover
      row.classList.add('bg-gray-100', 'dark:bg-gray-500');
    }
    row.setAttribute('tabindex', '0');
  }
  
  removeHighlight(row) {
    // Remove all possible hover classes
    row.classList.remove('bg-gray-100', 'dark:bg-gray-500', 'bg-lime-200');
  }
  
  selectCurrentRow(rows) {
    if (this.currentIndex >= 0 && this.currentIndex < rows.length) {
      const row = rows[this.currentIndex];
      // Trigger click on the row to select the ticket
      row.click();
    }
  }
  
  returnToSearch() {
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.focus();
      this.currentIndex = -1;
    }
  }
}
