import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Connects to data-controller="tag-input"
export default class extends Controller {
  static values = {
    existingTags: Array
  }

  connect() {
    // Create tags input field for better UX
    const inputField = this.element;
    const tagsArray = inputField.value.split(',').map(tag => tag.trim()).filter(tag => tag !== '');

    // Save original input field for later reference
    this.originalInput = inputField;

    // Save bound references for cleanup in disconnect()
    this.boundHandleFormSubmit = this.handleFormSubmit.bind(this)
    this.boundHandleDocumentClick = this._handleDocumentClick.bind(this)

    // Initialize the input field with tags
    this.initializeTagsInput(inputField, tagsArray);

    // Listen for form submission to format tags
    this.form = inputField.closest('form');
    if (this.form) {
      this.form.addEventListener('submit', this.boundHandleFormSubmit);
    }

    // Global click listener to hide suggestions when clicking outside
    document.addEventListener('click', this.boundHandleDocumentClick);
  }

  disconnect() {
    // Remove global document click listener
    document.removeEventListener('click', this.boundHandleDocumentClick)

    // Remove form submit listener
    if (this.form) {
      this.form.removeEventListener('submit', this.boundHandleFormSubmit)
      this.form = null
    }

    // Clear blur timeout
    if (this._blurTimeout) {
      clearTimeout(this._blurTimeout)
      this._blurTimeout = null
    }

    // Remove injected style element
    if (this._styleElement) {
      this._styleElement.remove()
      this._styleElement = null
    }

    // Remove dynamically created container
    if (this._container) {
      this._container.remove()
      this._container = null
    }

    // Restore original input visibility
    if (this.originalInput) {
      this.originalInput.style.display = ''
    }
  }

  _handleDocumentClick(e) {
    if (this._container && this._suggestionsContainer) {
      if (!this._container.contains(e.target) && !this._suggestionsContainer.contains(e.target)) {
        this._suggestionsContainer.classList.add('hidden');
        this._activeSuggestionIndex = -1;
      }
    }
  }

  initializeTagsInput(inputField, initialTags) {
    // Create container for tags
    const container = document.createElement('div');
    // Neo-brutalist design - adapted to match select fields
    container.className = 'ss-values-div flex flex-wrap gap-2 px-3 py-2 border border-black rounded-md bg-white hover:shadow-[2px_2px_0_0_#000000] hover:-translate-x-0.5 hover:-translate-y-0.5 focus-within:shadow-[2px_2px_0_0_#000000] focus-within:-translate-x-0.5 focus-within:-translate-y-0.5 transition-all duration-200';
    container.style.minHeight = '38px';
    container.style.position = 'relative';
    container.style.marginTop = '0.25rem';

    // Save reference for cleanup
    this._container = container;

    // Replace the input field with the container
    inputField.parentNode.insertBefore(container, inputField);

    // Keep original form field but hide it
    // This ensures the original field is still submitted
    inputField.style.display = 'none';

    // Add initial tags
    initialTags.forEach(tag => {
      this.addTag(container, inputField, tag);
    });

    // Create new tag input
    const newTagInput = document.createElement('input');
    newTagInput.type = 'text';
    newTagInput.className = 'flex-grow min-w-[100px] outline-none border-none text-sm py-1';
    newTagInput.placeholder = I18n.t('stimulus.tag_input.add_tag_placeholder');
    newTagInput.setAttribute('data-tag-input-control', 'visible-input');
    container.appendChild(newTagInput);

    // Create suggestions container with neo-brutalist style
    const suggestionsContainer = document.createElement('div');
    suggestionsContainer.className = 'absolute z-dropdown left-0 right-0 mt-1 max-h-60 overflow-auto rounded-lg bg-white text-sm shadow-[2px_2px_0_0_#000000] focus:outline-none border border-black hidden';
    suggestionsContainer.style.top = '100%';
    container.appendChild(suggestionsContainer);

    // Save reference for cleanup and document click handler
    this._suggestionsContainer = suggestionsContainer;

    // Set focus to the new tag input when clicking on the container
    container.addEventListener('click', () => {
      newTagInput.focus();
    });

    // Handle input event for suggestions
    newTagInput.addEventListener('input', () => {
      const value = newTagInput.value.trim().toLowerCase();

      // Clear suggestions
      suggestionsContainer.innerHTML = '';

      // Reset active suggestion index
      this._activeSuggestionIndex = -1;

      if (value.length > 0 && this.existingTagsValue && this.existingTagsValue.length > 0) {
        // Get suggestions based on input
        const suggestions = this.existingTagsValue.filter(tag =>
          tag.toLowerCase().includes(value) &&
          !this.getExistingTagNames(container).includes(tag.toLowerCase())
        );

        // Add suggestion elements
        if (suggestions.length > 0) {
          suggestions.forEach(suggestion => {
            const suggestionItem = document.createElement('div');
            suggestionItem.className = 'cursor-pointer select-none px-3 py-2 hover:bg-gray-100 text-black';
            suggestionItem.textContent = suggestion;
            suggestionItem.addEventListener('click', () => {
              this.addTag(container, inputField, suggestion);
              newTagInput.value = '';
              suggestionsContainer.classList.add('hidden');
              this._activeSuggestionIndex = -1;
              newTagInput.focus();
            });
            suggestionsContainer.appendChild(suggestionItem);
          });

          // Show suggestions
          suggestionsContainer.classList.remove('hidden');
        } else {
          suggestionsContainer.classList.add('hidden');
        }
      } else {
        suggestionsContainer.classList.add('hidden');
      }
    });

    // Global click listener for hiding suggestions is registered in connect()
    // and uses this.boundHandleDocumentClick with _handleDocumentClick method

    // Track active suggestion index
    this._activeSuggestionIndex = -1;
    let suggestionsItems = [];

    // Add style for active suggestion
    const style = document.createElement('style');
    style.textContent = `
      .tag-suggestion-active {
        background-color: #f5f5f5;
      }
    `;
    document.head.appendChild(style);
    this._styleElement = style;

    // Handle key events
    newTagInput.addEventListener('keydown', (e) => {
      suggestionsItems = suggestionsContainer.querySelectorAll('div');
      const suggestions = Array.from(suggestionsItems);

      if (e.key === 'Enter') {
        e.preventDefault();
        if (this._activeSuggestionIndex >= 0 && this._activeSuggestionIndex < suggestions.length) {
          // If a suggestion is selected, add it
          const selectedSuggestion = suggestions[this._activeSuggestionIndex].textContent;
          this.addTag(container, inputField, selectedSuggestion);
          newTagInput.value = '';
          suggestionsContainer.classList.add('hidden');
          this._activeSuggestionIndex = -1;
        } else {
          // Otherwise use the entered text
          const tagValue = newTagInput.value.trim();
          if (tagValue) {
            this.addTag(container, inputField, tagValue);
            newTagInput.value = '';
            suggestionsContainer.classList.add('hidden');
          }
        }
      } else if (e.key === ',') {
        e.preventDefault();
        const tagValue = newTagInput.value.trim();
        if (tagValue) {
          this.addTag(container, inputField, tagValue);
          newTagInput.value = '';
          suggestionsContainer.classList.add('hidden');
          this._activeSuggestionIndex = -1;
        }
      } else if (e.key === 'Backspace' && newTagInput.value === '') {
        // Remove the last tag if backspace is pressed on empty input
        const tags = container.querySelectorAll('.tag');
        if (tags.length > 0) {
          const lastTag = tags[tags.length - 1];
          this.removeTag(container, inputField, lastTag);
        }
      } else if (e.key === 'ArrowDown' && !suggestionsContainer.classList.contains('hidden')) {
        // Navigate to next suggestion
        e.preventDefault();

        if (suggestions.length > 0) {
          // Remove active class from previous selection
          if (this._activeSuggestionIndex >= 0) {
            suggestions[this._activeSuggestionIndex].classList.remove('tag-suggestion-active');
          }

          // Increment index or wrap around
          this._activeSuggestionIndex = (this._activeSuggestionIndex + 1) % suggestions.length;

          // Add active class to new selection
          suggestions[this._activeSuggestionIndex].classList.add('tag-suggestion-active');

          // Ensure the item is visible in the scrollable container
          suggestions[this._activeSuggestionIndex].scrollIntoView({ block: 'nearest' });
        }
      } else if (e.key === 'ArrowUp' && !suggestionsContainer.classList.contains('hidden')) {
        // Navigate to previous suggestion
        e.preventDefault();

        if (suggestions.length > 0) {
          // Remove active class from previous selection
          if (this._activeSuggestionIndex >= 0) {
            suggestions[this._activeSuggestionIndex].classList.remove('tag-suggestion-active');
          }

          // Decrement index or wrap around
          this._activeSuggestionIndex = this._activeSuggestionIndex <= 0 ?
            suggestions.length - 1 : this._activeSuggestionIndex - 1;

          // Add active class to new selection
          suggestions[this._activeSuggestionIndex].classList.add('tag-suggestion-active');

          // Ensure the item is visible in the scrollable container
          suggestions[this._activeSuggestionIndex].scrollIntoView({ block: 'nearest' });
        }
      } else if (e.key === 'Escape') {
        suggestionsContainer.classList.add('hidden');
        this._activeSuggestionIndex = -1;
      }
    });

    // Handle blur event to add tag and hide suggestions with delay
    newTagInput.addEventListener('blur', (e) => {
      const tagValue = newTagInput.value.trim();
      if (tagValue) {
        // Only add tag if we're not clicking on a suggestion
        if (!suggestionsContainer.contains(e.relatedTarget)) {
          this.addTag(container, inputField, tagValue);
          newTagInput.value = '';
        }
      }

      // Hide suggestions with delay to allow clicking on suggestions
      this._blurTimeout = setTimeout(() => {
        if (!suggestionsContainer.contains(document.activeElement)) {
          suggestionsContainer.classList.add('hidden');
          this._activeSuggestionIndex = -1;
        }
        this._blurTimeout = null
      }, 150);
    });
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // Its Escape listens on its own field, so only a key pressed there counts.
  ownsEscape() {
    const suggestions = this._suggestionsContainer
    return Boolean(suggestions) && !suggestions.classList.contains('hidden') &&
      Boolean(suggestions.parentElement?.contains(document.activeElement))
  }

  getExistingTagNames(container) {
    return Array.from(container.querySelectorAll('.ss-value-text')).map(tag => tag.textContent.toLowerCase());
  }

  addTag(container, inputField, tagValue) {
    // Skip if tag is empty or already exists
    if (!tagValue) return;

    const existingTags = this.getExistingTagNames(container);
    if (existingTags.includes(tagValue.toLowerCase())) return;

    // Create tag element with neo-brutalist style
    const tag = document.createElement('div');
    tag.className = 'ss-value tag';
    tag.style.display = 'inline-flex';
    tag.style.alignItems = 'center';
    tag.style.padding = '2px 8px';
    tag.style.margin = '2px 4px 2px 0';
    tag.style.backgroundColor = '#f5f5f5';
    tag.style.borderRadius = '0.5rem';
    tag.style.border = '1px solid black';
    tag.dataset.id = Math.random().toString(36).substring(2, 10); // Random ID like SlimSelect

    // Create tag text element - using div instead of span
    const tagText = document.createElement('div');
    tagText.className = 'ss-value-text tag-text';
    tagText.style.fontSize = '14px';
    tagText.style.fontWeight = '500';
    tagText.style.padding = '0 4px';
    tagText.textContent = tagValue;

    // Create delete button - using div instead of button
    const removeBtn = document.createElement('div');
    removeBtn.className = 'ss-value-delete text-gray-500 hover:text-gray-700 focus:outline-none';
    removeBtn.style.display = 'flex';
    removeBtn.style.alignItems = 'center';
    removeBtn.style.justifyContent = 'center';
    removeBtn.style.width = '15px';
    removeBtn.style.height = '15px';
    removeBtn.style.margin = '0 5px';
    removeBtn.style.cursor = 'pointer';

    // Create SVG X icon
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 100 100');
    svg.style.width = '8px';
    svg.style.height = '8px';

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M10,10 L90,90 M10,90 L90,10');
    path.style.stroke = 'currentColor';
    path.style.strokeWidth = '16';
    path.style.fill = 'none';

    svg.appendChild(path);
    removeBtn.appendChild(svg);

    // Add click event to remove tag
    removeBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      this.removeTag(container, inputField, tag);
    });

    tag.appendChild(tagText);
    tag.appendChild(removeBtn);

    // Add tag before the input
    const newTagInput = container.querySelector('input');
    container.insertBefore(tag, newTagInput);

    // Update the original input field
    this.updateOriginalInput(container, inputField);
  }

  removeTag(container, inputField, tagElement) {
    container.removeChild(tagElement);
    this.updateOriginalInput(container, inputField);
  }

  updateOriginalInput(container, inputField) {
    const tags = Array.from(container.querySelectorAll('.ss-value-text')).map(tag => tag.textContent);
    inputField.value = tags.join(', ');

    // Find the associated hidden field and update it
    const hiddenFieldId = inputField.id.replace('visible', 'list');
    const hiddenField = document.getElementById(hiddenFieldId);
    if (hiddenField) {
      hiddenField.value = tags.join(', ');

      // Also dispatch a change event on the hidden field to ensure all listeners are notified
      hiddenField.dispatchEvent(new Event('change', { bubbles: true }));
    }

    // Dispatch a change event on the input field so listeners are notified
    inputField.dispatchEvent(new Event('change', { bubbles: true }));

    // Also find the form and store the tag value as a data attribute
    const form = inputField.closest('form');
    if (form) {
      form.dataset.tagList = tags.join(', ');
    }
  }

  handleFormSubmit(event) {
    // Make sure tags are correctly synced before submission
    if (this.originalInput) {
      const container = this.originalInput.parentNode.querySelector('.ss-values-div');
      if (container) {
        const tags = Array.from(container.querySelectorAll('.ss-value-text')).map(tag => tag.textContent);
        const tagString = tags.join(', ');

        // Set value of original input
        this.originalInput.value = tagString;
      }
    }
  }
}
