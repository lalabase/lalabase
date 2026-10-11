// app/javascript/controllers/smart_folder_form_controller.js
import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// This controller handles the dynamic aspects of the Smart Folder form,
// including adding/removing rule groups and rules as well as
// the dynamic update of operator and value fields based on the field selection.
export default class extends Controller {
  // Targets for DOM elements
  static targets = [
    "ruleGroupsContainer", // Container for all rule groups
    "ruleGroupTemplate",   // Template for new rule groups
    "ruleTemplate",        // Template for new rules
    "rule",                // Each individual rule
    "fieldSelect",         // The field dropdown in a rule
    "operatorSelect",      // The operator dropdown in a rule
    "valueContainer",      // Container for the value field
    "referenceSelect",     // Select for reference values (optional, e.g. for status, user)
    "rangeStartInput",     // Input field for the start value of a range (e.g. 'between' operator)
    "rangeEndInput",       // Input field for the end value of a range
    "hiddenValueField",    // Hidden field that stores combined values for ranges
    "tagInput",           // Input field for tags
    "tagSuggestions",     // Container for tag suggestions
    "removeRuleBtn",      // Button to remove a rule
    "removeGroupBtn",     // Button to remove a group
    "multiSelect",        // Multi-select for in_list/not_in_list operators
    "multiSelectHidden"   // Hidden field for the combined comma string
  ]

  // Values passed in via data attributes
  static values = {
    fieldOperatorsUrl: String,     // URL for the API endpoint for operator options based on the field
    referenceOptionsUrl: String    // URL for the API endpoint for reference options for certain fields
  }
  
  // Stores the current tag suggestions
  tagSuggestions = [];

  // Lifecycle method: on initialization
  connect() {
    // Smart Folder Form Controller connected

    // Track timers for cleanup
    this._focusOutTimer = null;

    // Store the current object type
    const objectTypeSelect = document.querySelector('select[name="smart_folder[target_object_type]"]');
    if (objectTypeSelect) {
      this.currentObjectType = objectTypeSelect.value;

      // Filter all already existing field selects
      this.filterFieldSelectsByObjectType(this.currentObjectType);
    }

    // On load we update the state of all buttons
    this.updateRemoveRuleButtonStates();
    this.updateRemoveGroupButtonStates();
  }

  // Lifecycle method: cleanup
  disconnect() {
    if (this._focusOutTimer) {
      clearTimeout(this._focusOutTimer);
    }
  }
  
  // Updates the visibility of the delete-group buttons
  updateRemoveGroupButtonStates() {
    // Count the visible groups (not marked as deleted)
    const visibleGroups = Array.from(
      this.element.querySelectorAll('.smart-folder-rule-group')
    ).filter(group => group.style.display !== 'none');
    
    // Update remove group button states
    
    // If there is only one group, we hide its delete button
    if (visibleGroups.length <= 1) {
      // Disable the button for the only group
      const singleGroup = visibleGroups[0];
      if (singleGroup) {
        const removeButton = singleGroup.querySelector('[data-smart-folder-form-target="removeGroupBtn"]');
        if (removeButton) {
          removeButton.style.display = 'none';
        }
      }
    } else {
      // Otherwise show all delete-group buttons
      visibleGroups.forEach(group => {
        const removeButton = group.querySelector('[data-smart-folder-form-target="removeGroupBtn"]');
        if (removeButton) {
          removeButton.style.display = '';
        }
      });
    }
  }
  
  // Updates the state of the minus buttons for all rule groups
  updateRemoveRuleButtonStates() {
    // Go through all rule groups
    const groups = this.element.querySelectorAll('.smart-folder-rule-group');
    
    groups.forEach(group => {
      // Count visible rules in this group
      const visibleRules = Array.from(
        group.querySelectorAll('.smart-folder-rule')
      ).filter(rule => rule.style.display !== 'none');
      
      // If only one rule is visible, disable its minus icon
      if (visibleRules.length === 1) {
        const singleRule = visibleRules[0];
        const removeButton = singleRule.querySelector('.remove-rule-btn');
        
        // Only gray out the icon, the button itself stays normal
        if (removeButton) {
          // With this new design we set the text color to gray and remove the shadow for the disabled state
          removeButton.classList.add('text-gray-400', 'border-gray-400');
          removeButton.classList.remove('border-stroke', 'hover:shadow-sm', 'focus:shadow-sm');
          
          // IMPORTANT: We set the data-disabled attribute to check in the click handler
          // whether the icon should be disabled (not a real button deactivation)
          removeButton.setAttribute('data-disabled', 'true');
        }
      } else {
        // Otherwise enable all minus icons
        visibleRules.forEach(rule => {
          const removeButton = rule.querySelector('.remove-rule-btn');
          
          // Enable icon
          if (removeButton) {
            // With the new design we reset the button's classes
            removeButton.classList.remove('text-gray-400', 'border-gray-400');
            removeButton.classList.add('border-stroke', 'hover:shadow-sm', 'focus:shadow-sm');
            
            // Remove attribute
            removeButton.removeAttribute('data-disabled');
          }
        });
      }
    });
  }
  
  // Called when the object type is changed
  objectTypeChanged(event) {
    const newObjectType = event.currentTarget.value;
    // Object type changed
    
    // Store for later comparison
    this.currentObjectType = newObjectType;
    
    // Update all field selects
    this.filterFieldSelectsByObjectType(newObjectType);
  }
  
  // Filters all field selects based on the selected object type
  filterFieldSelectsByObjectType(objectType) {
    // Find all field selects in the form
    const fieldSelects = this.element.querySelectorAll('[data-smart-folder-form-target="fieldSelect"]');
    
    fieldSelects.forEach(fieldSelect => {
      const originalOptions = Array.from(fieldSelect.options);
      const selectedValue = fieldSelect.value;
      
      // Empty the select
      fieldSelect.innerHTML = '';
      
      // Add empty option
      const emptyOption = document.createElement('option');
      emptyOption.value = '';
      emptyOption.textContent = I18n.t('stimulus.smart_folder.please_select');
      fieldSelect.appendChild(emptyOption);
      
      // Filter the options and add them back
      originalOptions.forEach(option => {
        if (option.value === '') return; // Skip empty option
        
        // Check whether the option is applicable to the object type
        const applicableTypes = option.dataset.applicableTypes ? 
                             JSON.parse(option.dataset.applicableTypes) : [];
        
        // Add if "All" or if the current type is contained in applicableTypes
        if (objectType === 'All' || applicableTypes.includes(objectType)) {
          const newOption = document.createElement('option');
          newOption.value = option.value;
          newOption.textContent = option.textContent;
          
          // Copy dataset attributes
          Object.keys(option.dataset).forEach(key => {
            newOption.dataset[key] = option.dataset[key];
          });
          
          fieldSelect.appendChild(newOption);
        }
      });
      
      // Restore the previous selection if possible
      if (selectedValue) {
        // Check whether the selected option is still available
        const stillAvailable = Array.from(fieldSelect.options).some(opt => opt.value === selectedValue);
        if (stillAvailable) {
          fieldSelect.value = selectedValue;
        } else {
          // If not, reset and hide the operator/value container if needed
          fieldSelect.value = '';
          const rule = fieldSelect.closest('.smart-folder-rule');
          
          if (rule) {
            const operatorSelect = rule.querySelector('[data-smart-folder-form-target="operatorSelect"]');
            const valueContainer = rule.querySelector('[data-smart-folder-form-target="valueContainer"]');
            
            if (operatorSelect) {
              operatorSelect.innerHTML = `<option value="">${I18n.t('stimulus.smart_folder.please_select')}</option>`;
            }
            
            if (valueContainer) {
              valueContainer.style.visibility = 'hidden';
            }
          }
        }
      }
    });
  }

  // Add rule group
  addRuleGroup(event) {
    event.preventDefault();
    
    // Get the template content
    const content = this.ruleGroupTemplateTarget.innerHTML;
    
    // Child indices MUST be pure integers: Rails' strong params only treat
    // integer-like keys as fields_for-style nested attributes; a prefixed key
    // like "new_group_<ts>" is silently dropped by permit() and never saved.
    const timestamp = new Date().getTime();

    // Update the template with new child indices — the group template ships
    // with one nested rule that carries its own NEW_RULE_RECORD placeholder
    let newContent = content.replace(/NEW_GROUP_RECORD/g, `${timestamp}`);
    newContent = newContent.replace(/NEW_RULE_RECORD/g, `${timestamp + 1}`);
    
    // Add to the DOM - directly at the end of the container, before the "Add Rule Group" button
    this.ruleGroupsContainerTarget.insertAdjacentHTML('beforeend', newContent);
    
    // After adding a new group we need to update the visibility of the delete buttons
    this.updateRemoveGroupButtonStates();
  }
  
  // Add rule to a group
  addRule(event) {
    event.preventDefault();
    
    // Find the button that was clicked
    const button = event.currentTarget;
    
    // Find the parent rule group - either directly via the button
    // or via the parent rule, if the plus button was clicked inside a rule
    let groupContainer;
    if (button.closest('.smart-folder-rule')) {
      // The button is inside a rule
      const ruleContainer = button.closest('.smart-folder-rule');
      groupContainer = ruleContainer.closest('.smart-folder-rule-group');
    } else {
      // The button is directly in the group
      groupContainer = button.closest('.smart-folder-rule-group');
    }
    
    const groupId = groupContainer.getAttribute('data-group-index');
    
    // Find the container for rules in this group
    const rulesContainer = groupContainer.querySelector('.rules-container');
    
    // Get the template content
    const content = this.ruleTemplateTarget.innerHTML;
    
    // Pure-integer child index for the new rule (see addRuleGroup: prefixed
    // keys are silently dropped by Rails' strong params)
    const timestamp = new Date().getTime();

    // Update the template with IDs
    let newContent = content.replace(/NEW_GROUP_RECORD/g, groupId);
    newContent = newContent.replace(/NEW_RULE_RECORD/g, `${timestamp}`);
    
    // Add to the DOM
    rulesContainer.insertAdjacentHTML('beforeend', newContent);
    
    // Scroll down to show the new rule
    rulesContainer.scrollTop = rulesContainer.scrollHeight;
    
    // Update the state of the remove buttons
    this.updateRemoveRuleButtonStates();
  }
  
  // Remove rule group
  removeRuleGroup(event) {
    event.preventDefault();
    
    // Find the button that was clicked
    const button = event.currentTarget;
    
    // Find the rule group
    const group = button.closest('.smart-folder-rule-group');
    
    // Find the _destroy field and set it to 1 if it already exists in the DOM
    const destroyField = group.querySelector('input[name$="[_destroy]"]');
    
    if (destroyField) {
      destroyField.value = "1";
      // Hide the group
      group.style.display = 'none';
      // Prevent the now-hidden required field/operator selects from blocking
      // form submission (see clearValidationInSubtree).
      this.clearValidationInSubtree(group);
    } else {
      // If the field does not exist, remove directly from DOM (new group)
      group.remove();
    }

    // After removing a group we need to update the visibility of the delete buttons
    this.updateRemoveGroupButtonStates();
  }
  
  // Remove rule
  removeRule(event) {
    event.preventDefault();
    
    // Find the button that was clicked
    const button = event.currentTarget;
    
    // If the button is marked as disabled (via data attribute), do nothing
    if (button.getAttribute('data-disabled') === 'true') {
      return;
    }
    
    // Find the rule
    const rule = button.closest('.smart-folder-rule');
    
    // Find the group the rule belongs to
    const group = rule.closest('.smart-folder-rule-group');
    
    // Count all visible rules in the group (excluding those hidden with display:none)
    const visibleRules = Array.from(
      group.querySelectorAll('.smart-folder-rule')
    ).filter(el => el.style.display !== 'none' && el !== rule);
    
    // If this is the last rule in the group, remove the whole group
    if (visibleRules.length === 0) {
      // Call removeRuleGroup with a simulated event
      const deleteGroupEvent = { preventDefault: () => {} };
      deleteGroupEvent.currentTarget = group.querySelector('[data-action*="smart-folder-form#removeRuleGroup"]');
      this.removeRuleGroup(deleteGroupEvent);
      return;
    }
    
    // Find the _destroy field and set it to 1 if it already exists in the DOM
    const destroyField = rule.querySelector('input[name$="[_destroy]"]');
    
    if (destroyField) {
      destroyField.value = "1";
      // Hide the rule
      rule.style.display = 'none';
      // Prevent the now-hidden required field/operator selects from blocking
      // form submission (see clearValidationInSubtree).
      this.clearValidationInSubtree(rule);
    } else {
      // If the field does not exist, remove directly from DOM (new rule)
      rule.remove();
    }

    // Update the state of the remove buttons
    this.updateRemoveRuleButtonStates();
  }

  // Strips HTML5 `required` from every control inside a soft-deleted
  // (display:none, _destroy=1) subtree. Without this the browser still runs
  // constraint validation on the hidden, empty required field/operator selects,
  // fails, cannot focus them ("An invalid form control ... is not focusable"),
  // and silently refuses to submit — the Save button appears dead. The record
  // is marked for destruction, so the server ignores its attributes anyway.
  clearValidationInSubtree(element) {
    element.querySelectorAll('[required]').forEach((control) => {
      control.removeAttribute('required');
    });
  }
  
  // Field dropdown changed -> load operator options
  async fieldChanged(event) {
    event.preventDefault();
    
    // Find the changed field
    const fieldSelect = event.currentTarget;
    const selectedField = fieldSelect.value;
    // Field changed
    
    // Find the rule that contains the field
    const rule = fieldSelect.closest('.smart-folder-rule');
    
    // Save the field values in the rule's dataset attributes
    rule.dataset.field = selectedField;
    
    // Find the operator dropdown in this rule
    const operatorSelect = rule.querySelector('[data-smart-folder-form-target="operatorSelect"]');
    
    // Find the value container in this rule
    const valueContainer = rule.querySelector('[data-smart-folder-form-target="valueContainer"]');
    
    // If no selection was made, reset the operator and value fields
    if (!selectedField) {
      operatorSelect.innerHTML = `<option value="">${I18n.t('stimulus.smart_folder.please_select')}</option>`;
      valueContainer.style.visibility = 'hidden';
      return;
    }
    
    // Call the operators API to get the valid operators for this field
    try {
      const url = this.fieldOperatorsUrlValue.replace(':field', selectedField);
      // Fetching operators
      
      const response = await fetch(url, {
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      });
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      
      const data = await response.json();
      // Received operators data
      
      // Update the operator dropdown
      operatorSelect.innerHTML = `<option value="">${I18n.t('stimulus.smart_folder.please_select')}</option>`; // Empty option
      
      if (data.operators && data.operators.length > 0) {
        data.operators.forEach(op => {
          const option = document.createElement('option');
          option.value = op.value;
          option.textContent = op.label;
          operatorSelect.appendChild(option);
        });
      }
      
      // Reset the previous selection
      rule.dataset.operator = '';
      
      // Make the value container invisible until an operator is selected
      valueContainer.style.visibility = 'hidden';
      
      // Cache field config data for later use
      rule.dataset.valueType = data.valueType;
      if (data.referenceModel) {
        rule.dataset.referenceModel = data.referenceModel;
      }
      // The field's valueless operators, owned by SmartFolderRule.optional_value_operators
      rule.dataset.valueless = JSON.stringify(data.valueless || []);
      // Cache whether it is a tag field (for the tagsAutocomplete functionality)
      rule.dataset.isTagField = selectedField === 'tag' ? 'true' : 'false';
      
      // Cache custom attribute options if present
      if (data.custom && data.customOptions) {
        rule.dataset.isCustomField = 'true';
        rule.dataset.customOptions = JSON.stringify(data.customOptions);
      } else {
        rule.dataset.isCustomField = 'false';
      }
      
    } catch (error) {
      console.error('Error fetching operators:', error);
      operatorSelect.innerHTML = `<option value="">${I18n.t('stimulus.general.loading_operators_error')}</option>`;
    }
  }
  
  // Operator dropdown changed -> update value field
  async operatorChanged(event) {
    // Operator changed
    
    // The operator was changed, now we should adjust the value input fields accordingly
    const operatorSelect = event.currentTarget;
    const selectedOperator = operatorSelect.value;
    const rule = operatorSelect.closest('.smart-folder-rule');
    
    // Save the operator in the rule's dataset attributes
    rule.dataset.operator = selectedOperator;
    
    // Find the original field select to determine the field type
    const fieldSelect = rule.querySelector('[data-smart-folder-form-target="fieldSelect"]');
    const selectedField = rule.dataset.field || fieldSelect.value;
    
    // Store the operator for tag field validation
    if (selectedField === 'tag') {
      rule.dataset.tagOperator = selectedOperator;
    }
    
    // Find the value container
    const valueContainer = rule.querySelector('[data-smart-folder-form-target="valueContainer"]');
    
    // If no operator was selected, hide or disable the value field
    if (!selectedOperator || !selectedField) {
      // Simple implementation: hide the value field
      valueContainer.style.visibility = 'hidden';
      return;
    }
    
    // Extract group and rule index
    const ruleId = rule.id; // Format: smart_folder_rule_123
    const groupContainer = rule.closest('.smart-folder-rule-group');
    const groupIndex = groupContainer.dataset.groupIndex;
    const ruleIndex = rule.dataset.ruleIndex;
    
    // Rule info collected
    
    // To show the correct input fields we need to know the field type
    // We use the cached data from fieldChanged, or reload it
    try {
      let valueType, referenceModel;
      
      // Declare the data variable we will need later
      let data = null;
      
      // Check whether we have already cached the data
      if (rule.dataset.valueType) {
        valueType = rule.dataset.valueType;
        referenceModel = rule.dataset.referenceModel;
        
        // Make sure we know whether it is a tag field
        if (rule.dataset.isTagField !== undefined) {
          rule.dataset.isTagField = rule.dataset.isTagField || (selectedField === 'tag' ? 'true' : 'false');
        } else {
          rule.dataset.isTagField = selectedField === 'tag' ? 'true' : 'false';
        }
      } else {
        // If not, we load it again
        const url = this.fieldOperatorsUrlValue.replace(':field', selectedField);
        
        const response = await fetch(url, {
          headers: {
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest'
          }
        });
        
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        data = await response.json();
        // Field config received for value container
        
        valueType = data.valueType;
        referenceModel = data.referenceModel;
        
        // Cache for later use
        rule.dataset.valueType = valueType;
        if (referenceModel) {
          rule.dataset.referenceModel = referenceModel;
        }
        rule.dataset.valueless = JSON.stringify(data.valueless || []);
      }

      // The operators of this field that take no value (is_empty, the deadline presets, the
      // date presets). One owner: SmartFolderRule.optional_value_operators, handed over by
      // the field_operators API; no copy of the list here.
      const valueless = JSON.parse(rule.dataset.valueless || '[]');

      // Create the appropriate input field based on the field type and operator
      let valueInput = "";
      
      // Construct the name for the form fields
      const namePrefix = `smart_folder[smart_folder_rule_groups_attributes][${groupIndex}][smart_folder_rules_attributes][${ruleIndex}]`;
      
      // Check whether it is a tag field (either from the cache or based on the field name)
      const isTagField = rule.dataset.isTagField === 'true' || selectedField === 'tag';
      
      // Check whether it is a custom field with options
      const isCustomField = rule.dataset.isCustomField === 'true';
      const customOptions = isCustomField && rule.dataset.customOptions ? JSON.parse(rule.dataset.customOptions) : null;
      
      switch(valueType) {
        case "reference_set":
          await this.renderReferenceSet(selectedField, valueContainer, namePrefix)
          return

        case "text":
          // If it is a custom field with select options
          if (isCustomField && customOptions && customOptions.length > 0) {
            // Deliberate duplication across the JS/Ruby boundary: this is the LIST_MEMBERSHIP
            // group owned by SmartFolders::Operators (app/models/smart_folders/operators.rb).
            // Ruby constants are not reachable here — change both sides together.
            const isListOperator = ['in_list', 'not_in_list'].includes(selectedOperator);

            this.renderCustomOptions(valueContainer, customOptions, namePrefix, isListOperator);
            valueContainer.style.visibility = 'visible';
            return;
          }
          // If it is a tag field, create a special tag autocomplete field
          else if (isTagField) {
            valueInput = `
              <div class="relative">
                <input type="text" 
                       name="${namePrefix}[value]" 
                       class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm tag-autocomplete" 
                       placeholder="${I18n.t('stimulus.smart_folder.tags_placeholder')}"
                       data-smart-folder-form-target="tagInput"
                       data-action="input->smart-folder-form#simpleTagSuggestions keydown->smart-folder-form#handleSimpleTagInputKey click->smart-folder-form#maybeShowTagSuggestions focusout->smart-folder-form#handleTagFocusOut"
                       autocomplete="off">
                <div class="absolute z-dropdown w-full mt-1 bg-white dark:bg-gray-800 rounded-md shadow-lg hidden tag-suggestions max-h-60 overflow-auto" data-smart-folder-form-target="tagSuggestions"></div>
                <div class="text-xs text-gray-500 mt-1">${I18n.t('stimulus.smart_folder.tag_input_hint')}</div>
              </div>
            `;
          } else {
            valueInput = `<input type="text" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="${I18n.t('stimulus.smart_folder.value_placeholder')}">`;
          }
          break;
        case "number":
          if (selectedOperator === 'between') {
            valueInput = `
              <div class="flex items-center space-x-2">
                <input type="number" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="Min" data-smart-folder-form-target="rangeStartInput" data-field-type="number" data-action="blur->smart-folder-form#updateCombinedValue">
                <span class="px-2 text-gray-500">-</span>
                <input type="number" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="Max" data-smart-folder-form-target="rangeEndInput" data-field-type="number" data-action="blur->smart-folder-form#updateCombinedValue">
                <input type="hidden" name="${namePrefix}[value]" data-smart-folder-form-target="hiddenValueField">
              </div>
            `;
          } else {
            valueInput = `<input type="number" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" min="0" step="any">`;
          }
          break;
        case "date":
          if (valueless.includes(selectedOperator)) {
            // Valueless: nothing to enter, and an empty value clears whatever the rule held
            valueInput = `<input type="hidden" name="${namePrefix}[value]" value="">`;
          } else if (selectedOperator === 'between') {
            valueInput = `
              <div class="flex items-center space-x-2">
                <input type="date" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" data-smart-folder-form-target="rangeStartInput" data-field-type="date" data-action="change->smart-folder-form#updateCombinedValue">
                <span class="px-2 text-gray-500">-</span>
                <input type="date" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" data-smart-folder-form-target="rangeEndInput" data-field-type="date" data-action="change->smart-folder-form#updateCombinedValue">
                <input type="hidden" name="${namePrefix}[value]" data-smart-folder-form-target="hiddenValueField">
              </div>
            `;
          } else if (['within_days', 'in_the_last_days'].includes(selectedOperator)) {
            // Deliberate duplication across the JS/Ruby boundary: the operator list above is the
            // RELATIVE_DATE group owned by SmartFolders::Operators
            // (app/models/smart_folders/operators.rb). Ruby constants are not reachable here —
            // change both sides together.
            valueInput = `
              <div class="flex items-center">
                <input type="number" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" min="1">
                <span class="pl-2 text-gray-700 dark:text-gray-300">Tage</span>
              </div>
            `;
          } else {
            valueInput = `<input type="date" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm">`;
          }
          break;
        case "boolean":
          valueInput = `
            <select name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm">
              <option value="">${I18n.t('stimulus.smart_folder.please_select')}</option>
              <option value="true">Ja</option>
              <option value="false">Nein</option>
            </select>
          `;
          break;
        case "reference":
          if (referenceModel) {
            // For reference fields we first need to load the options
            valueInput = `
              <select name="${namePrefix}[value]" 
                      class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm js-reference-select"
                      data-smart-folder-form-target="referenceSelect"
                      data-reference-model="${referenceModel}"
                      data-field="${selectedField}">
                <option value="">${I18n.t('stimulus.smart_folder.please_select')}</option>
                <!-- Options are loaded dynamically later -->
              </select>
            `;
            
            // Load reference options immediately
            this.loadReferenceOptions(selectedField, rule);
          } else {
            valueInput = `<input type="text" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="${I18n.t('stimulus.smart_folder.value_placeholder')}">`;
          }
          break;
        default: 
          valueInput = `<input type="text" name="${namePrefix}[value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="${I18n.t('stimulus.smart_folder.value_placeholder')}">`;
      }
      
      // Set the HTML content of the value container
      valueContainer.innerHTML = valueInput;
      valueContainer.style.visibility = 'visible';
      
    } catch (error) {
      console.error('Error updating value container:', error);
      valueContainer.innerHTML = `<input type="text" name="smart_folder[smart_folder_rule_groups_attributes][${groupIndex}][smart_folder_rules_attributes][${ruleIndex}][value]" class="block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm" placeholder="${I18n.t('stimulus.smart_folder.field_load_error')}">`;
      valueContainer.style.visibility = 'visible';
    }
  }
  
  // Labels and values are stored user input. Build nodes so neither can become markup.
  renderCustomOptions(container, options, namePrefix, multiple) {
    if (!multiple) {
      const select = document.createElement('select');
      select.name = `${namePrefix}[value]`;
      select.className = 'block w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:outline-none focus:ring-cobalt-500 focus:border-cobalt-500 sm:text-sm';
      select.append(new Option(I18n.t('stimulus.smart_folder.please_select'), ''));
      options.forEach(opt => select.append(new Option(opt.label, opt.value)));
      container.replaceChildren(select);
      return;
    }

    const list = document.createElement('div');
    list.className = 'border border-gray-300 rounded-md max-h-48 overflow-y-auto py-1';
    list.dataset.smartFolderFormTarget = 'multiSelect';
    options.forEach(opt => {
      const label = document.createElement('label');
      label.className = 'flex items-center gap-2 px-3 py-1.5 text-sm hover:bg-gray-100 cursor-pointer transition-colors';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.value = opt.value;
      checkbox.dataset.action = 'change->smart-folder-form#checkboxListChanged';
      checkbox.className = 'w-4 h-4 rounded border border-slate-200 text-cream-900 focus:ring-black focus:ring-offset-0';
      const text = document.createElement('span');
      text.className = 'text-xs';
      text.textContent = opt.label;
      label.append(checkbox, text);
      list.append(label);
    });
    const hidden = document.createElement('input');
    hidden.type = 'hidden';
    hidden.name = `${namePrefix}[value]`;
    hidden.dataset.smartFolderFormTarget = 'multiSelectHidden';
    container.replaceChildren(list, hidden);
  }

  // Updates the hidden value field for range inputs (e.g. 'between' operator)
  updateCombinedValue(event) {
    const input = event.currentTarget;
    const rule = input.closest('.smart-folder-rule');
    
    // Find the start and end inputs
    const startInput = rule.querySelector('[data-smart-folder-form-target="rangeStartInput"]');
    const endInput = rule.querySelector('[data-smart-folder-form-target="rangeEndInput"]');
    
    // Find the hidden field that stores the combined value
    const hiddenField = rule.querySelector('[data-smart-folder-form-target="hiddenValueField"]');
    
    if (startInput && endInput && hiddenField) {
      // Combine the values with a comma
      const combinedValue = `${startInput.value},${endInput.value}`;
      hiddenField.value = combinedValue;
    }
  }

  // Updates the hidden value field on checkbox-list changes (in_list/not_in_list)
  checkboxListChanged(event) {
    const checkbox = event.currentTarget
    const rule = checkbox.closest('.smart-folder-rule')
    const container = rule.querySelector('[data-smart-folder-form-target="multiSelect"]')
    const hiddenField = rule.querySelector('[data-smart-folder-form-target="multiSelectHidden"]')

    if (container && hiddenField) {
      const checked = container.querySelectorAll('input[type="checkbox"]:checked')
      const values = Array.from(checked).map(cb => cb.value)
      hiddenField.value = container.dataset.encoding === 'json' ? JSON.stringify(values) : values.join(',')
    }
  }
  
  async renderReferenceSet(field, container, namePrefix) {
    const sameField = container.querySelector('[data-encoding="json"]')?.dataset.referenceField === field
    const previous = sameField ? (container.querySelector('input[name$="[value]"]')?.value || '[]') : '[]'
    let selected
    try { selected = JSON.parse(previous) } catch { selected = [previous] }
    if (!Array.isArray(selected)) selected = [previous]
    const response = await fetch(this.referenceOptionsUrlValue.replace(':field', field), { headers: { Accept: 'application/json' } })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const { options = [] } = await response.json()
    for (const value of selected) {
      if (value && !options.some(option => option.value === value)) options.push({ value, label: value })
    }
    const list = document.createElement('div')
    list.className = 'border border-gray-300 rounded-md max-h-48 overflow-y-auto py-1'
    list.dataset.smartFolderFormTarget = 'multiSelect'
    list.dataset.encoding = 'json'
    list.dataset.referenceField = field
    for (const option of options) {
      const label = document.createElement('label')
      label.className = 'flex items-center gap-2 px-3 py-1.5 text-sm'
      const checkbox = document.createElement('input')
      checkbox.type = 'checkbox'
      checkbox.value = option.value
      checkbox.checked = selected.includes(option.value)
      checkbox.dataset.action = 'change->smart-folder-form#checkboxListChanged'
      const text = document.createElement('span')
      text.textContent = option.label
      label.append(checkbox, text)
      list.append(label)
    }
    const hidden = document.createElement('input')
    hidden.type = 'hidden'
    hidden.name = `${namePrefix}[value]`
    hidden.value = JSON.stringify(selected)
    hidden.dataset.smartFolderFormTarget = 'multiSelectHidden'
    container.replaceChildren(list, hidden)
    container.style.visibility = 'visible'
  }

  // Loads reference options for a field (e.g. status, user)
  async loadReferenceOptions(fieldName, rule) {
    // Loading reference options for field
    
    try {
      // Load reference options via API
      const url = this.referenceOptionsUrlValue.replace(':field', fieldName);
      // Fetching reference options
      
      const response = await fetch(url, {
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      });
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      
      const data = await response.json();
      // Received reference options
      
      // Find the referenceSelect in the current rule container
      const referenceSelect = rule.querySelector('[data-smart-folder-form-target="referenceSelect"]');
      
      if (!referenceSelect) {
        console.error('Reference select not found in rule:', rule);
        return;
      }
      
      const options = [new Option(I18n.t('stimulus.smart_folder.please_select'), '')];
      if (data.options && data.options.length > 0) {
        data.options.forEach(opt => options.push(new Option(opt.label, opt.value)));
      } else {
        const empty = new Option(I18n.t('stimulus.smart_folder.no_options'), '');
        empty.disabled = true;
        options.push(empty);
      }
      referenceSelect.replaceChildren(...options);
      
    } catch (error) {
      console.error('Error loading reference options:', error);
      const referenceSelect = rule.querySelector('[data-smart-folder-form-target="referenceSelect"]');
      if (referenceSelect) {
        referenceSelect.innerHTML = `<option value="">${I18n.t('stimulus.general.loading_options_error')}</option>`;
      }
    }
  }
  
  // Improved tag suggestions without a complex tag UI
  async simpleTagSuggestions(event) {
    const tagInput = event.target;
    if (!tagInput) return;
    
    const rule = tagInput.closest('.smart-folder-rule');
    if (!rule) return;
    
    const suggestionsContainer = rule.querySelector('[data-smart-folder-form-target="tagSuggestions"]');
    if (!suggestionsContainer) return;
    
    // Determine the current tag based on cursor position
    const currentTagInfo = this.getCurrentTagInfo(tagInput);
    
    // If the current tag is empty or has fewer than 2 characters, show no suggestions
    if (currentTagInfo.currentTag.length < 2) {
      suggestionsContainer.classList.add('hidden');
      return;
    }
    
    try {
      // API call with the current tag fragment
      const url = `${this.referenceOptionsUrlValue.replace(':field', 'tag')}?q=${encodeURIComponent(currentTagInfo.currentTag)}`;
      
      const response = await fetch(url, {
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      });
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      
      const data = await response.json();
      this.tagSuggestions = data.options || [];
      
      // Tags already selected in the input field
      const selectedTags = this.getSelectedTags(tagInput.value);
      
      // Filter out suggestions that are already selected
      const filteredSuggestions = this.tagSuggestions.filter(tag => {
        return !selectedTags.includes(tag.value.toLowerCase());
      });
      
      // Update the suggestions in the DOM
      this.showSimpleTagSuggestions(tagInput, suggestionsContainer, filteredSuggestions, currentTagInfo);
      
    } catch (error) {
      console.error('Error loading tag suggestions:', error);
      suggestionsContainer.classList.add('hidden');
    }
  }
  
  // Shows simple tag suggestions
  showSimpleTagSuggestions(tagInput, suggestionsContainer, suggestions, currentTagInfo) {
    suggestionsContainer.innerHTML = '';
    
    if (suggestions.length === 0) {
      suggestionsContainer.classList.add('hidden');
      return;
    }
    
    // Create a fragment for better performance
    const fragment = document.createDocumentFragment();
    
    suggestions.forEach((suggestion, index) => {
      const item = document.createElement('div');
      item.className = 'cursor-pointer px-3 py-2 hover:bg-gray-100 dark:hover:bg-gray-700';
      item.textContent = suggestion.label;
      item.setAttribute('data-index', index);
      
      // Insert tag on click
      item.addEventListener('click', () => {
        this.insertTagAtCursor(tagInput, suggestion.value, currentTagInfo);
        suggestionsContainer.classList.add('hidden');
        tagInput.focus();
      });
      
      fragment.appendChild(item);
    });
    
    // Insert all suggestions at once
    suggestionsContainer.appendChild(fragment);
    
    // Activate the first suggestion (visually)
    const firstItem = suggestionsContainer.querySelector('div');
    if (firstItem) {
      firstItem.classList.add('bg-gray-100', 'dark:bg-gray-700');
      suggestionsContainer.setAttribute('data-selected-index', '0');
    }
    
    // Show suggestions
    suggestionsContainer.classList.remove('hidden');
  }
  
  // Advanced keyboard commands in the tag input
  handleSimpleTagInputKey(event) {
    const tagInput = event.target;
    const rule = tagInput.closest('.smart-folder-rule');
    const suggestionsContainer = rule.querySelector('[data-smart-folder-form-target="tagSuggestions"]');
    
    // If no suggestions are visible, do nothing except on Escape
    if (suggestionsContainer.classList.contains('hidden') && event.key !== 'Escape') {
      return;
    }
    
    // All suggestions
    const suggestions = Array.from(suggestionsContainer.querySelectorAll('div'));
    
    // Current selection
    let selectedIndex = parseInt(suggestionsContainer.getAttribute('data-selected-index') || '0', 10);
    
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        // Select the next suggestion
        this.selectSuggestion(suggestions, selectedIndex + 1, suggestionsContainer);
        break;
        
      case 'ArrowUp':
        event.preventDefault();
        // Select the previous suggestion
        this.selectSuggestion(suggestions, selectedIndex - 1, suggestionsContainer);
        break;
        
      case 'Enter':
        // Only if suggestions are visible and there is at least one
        if (!suggestionsContainer.classList.contains('hidden') && suggestions.length > 0) {
          event.preventDefault();
          
          // Insert the currently selected suggestion
          const selectedItem = suggestions[selectedIndex];
          if (selectedItem) {
            const currentTagInfo = this.getCurrentTagInfo(tagInput);
            this.insertTagAtCursor(tagInput, selectedItem.textContent, currentTagInfo);
            suggestionsContainer.classList.add('hidden');
          }
        }
        break;
        
      case 'Escape':
        // Close suggestions
        suggestionsContainer.classList.add('hidden');
        break;
        
      case 'Tab':
        // On Tab, automatically insert the selected suggestion
        if (!suggestionsContainer.classList.contains('hidden') && suggestions.length > 0) {
          event.preventDefault();
          
          const selectedItem = suggestions[selectedIndex];
          if (selectedItem) {
            const currentTagInfo = this.getCurrentTagInfo(tagInput);
            this.insertTagAtCursor(tagInput, selectedItem.textContent, currentTagInfo);
            suggestionsContainer.classList.add('hidden');
          }
        }
        break;
        
      case ',':
        // When a comma is entered, close suggestions
        suggestionsContainer.classList.add('hidden');
        break;
    }
  }
  
  // Helper method to select a suggestion
  selectSuggestion(suggestions, newIndex, container) {
    if (suggestions.length === 0) return;
    
    // Make sure the index is within the valid range
    newIndex = Math.max(0, Math.min(newIndex, suggestions.length - 1));
    
    // Remove the current selection
    suggestions.forEach(item => {
      item.classList.remove('bg-gray-100', 'dark:bg-gray-700');
    });
    
    // Mark the new selection
    suggestions[newIndex].classList.add('bg-gray-100', 'dark:bg-gray-700');
    container.setAttribute('data-selected-index', newIndex.toString());
    
    // Scroll the selected option into view if needed
    suggestions[newIndex].scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
  
  // Inserts a selected tag at the cursor position and adds a comma
  insertTagAtCursor(input, tagValue, tagInfo) {
    if (!tagValue) return;
    
    // Determine the start and end position of the current tag
    const { startPos, endPos } = tagInfo;
    
    // Get the current operator for smarter insertion
    const rule = input.closest('.smart-folder-rule');
    const tagOperator = rule ? rule.dataset.tagOperator : '';
    // Deliberate duplication across the JS/Ruby boundary: this is the MULTI_TAG group owned by
    // SmartFolders::Operators (app/models/smart_folders/operators.rb). Ruby constants are not
    // reachable here — change both sides together.
    const allowMultipleTags = ['has_any_of', 'has_all_of'].includes(tagOperator);
    
    // Create the new value
    let newValue;
    
    // For multi-tag operators (has_any_of, has_all_of)
    if (allowMultipleTags) {
      newValue = input.value.substring(0, startPos) + tagValue + ', ' + input.value.substring(endPos);
    } else {
      // For single-tag operators (has, not_has) replace the whole value
      newValue = tagValue;
    }
    
    // Update the input
    input.value = newValue;
    
    // Set the cursor
    if (allowMultipleTags) {
      // Place the cursor after the inserted tag and comma
      const newCursorPos = startPos + tagValue.length + 2; // +2 for ', '
      input.setSelectionRange(newCursorPos, newCursorPos);
    } else {
      // For single-tag operators: place the cursor at the end
      input.setSelectionRange(newValue.length, newValue.length);
    }
  }
  
  // Determines the already selected tags from the input field
  getSelectedTags(inputValue) {
    if (!inputValue) return [];
    return inputValue.split(',').map(tag => tag.trim().toLowerCase()).filter(tag => tag.length > 0);
  }
  
  // Possibly shows tag suggestions when clicking into the input field
  maybeShowTagSuggestions(event) {
    const tagInput = event.currentTarget;
    if (!tagInput) return;
    
    // If there is already something in the field and it has enough characters, show suggestions
    const currentTagInfo = this.getCurrentTagInfo(tagInput);
    if (currentTagInfo.currentTag.length >= 2) {
      // Run the same logic as in simpleTagSuggestions
      this.simpleTagSuggestions(event);
    }
  }
  
  // Closes the suggestions when focus leaves the input field
  handleTagFocusOut(event) {
    // Small delay to detect whether a suggestion was clicked
    if (this._focusOutTimer) clearTimeout(this._focusOutTimer);
    this._focusOutTimer = setTimeout(() => {
      const tagInput = event.target;
      const rule = tagInput.closest('.smart-folder-rule');
      const suggestionsContainer = rule.querySelector('[data-smart-folder-form-target="tagSuggestions"]');
      
      // Check whether the new focus is inside the suggestions container
      const relatedTarget = event.relatedTarget;
      if (relatedTarget && suggestionsContainer.contains(relatedTarget)) {
        // Focus moved to a suggestion element, do nothing
        return;
      }
      
      // Otherwise close suggestions
      suggestionsContainer.classList.add('hidden');
      
      // Optional: clean up the value at the end - remove redundant commas
      this.cleanupTagInputValue(tagInput);
    }, 150); // Small timeout to wait for the click processing
  }
  
  // Cleans up the tag input value by removing redundant commas and spaces
  cleanupTagInputValue(input) {
    if (!input || !input.value) return;
    
    // Remove leading and trailing spaces
    let value = input.value.trim();
    
    // Remove duplicate commas and empty tags
    value = value.split(',')
                .map(tag => tag.trim())
                .filter(tag => tag.length > 0)
                .join(', ');
    
    // Get the current operator for smarter cleanup
    const rule = input.closest('.smart-folder-rule');
    const tagOperator = rule ? rule.dataset.tagOperator : '';
    
    // For single-tag operators keep only one tag. Deliberate duplication across the JS/Ruby
    // boundary: this is the complement of the MULTI_TAG group owned by SmartFolders::Operators
    // (app/models/smart_folders/operators.rb) — no Ruby consumer needs the pair on its own, so it
    // is not a constant there. Change both sides together.
    if (['has', 'not_has'].includes(tagOperator) && value.includes(',')) {
      // Take only the first tag
      value = value.split(',')[0].trim();
    }
    
    // Update the value
    if (value !== input.value) {
      input.value = value;
    }
    
    // If the SmartFolder is already being saved and the field is empty,
    // set a placeholder value to avoid validation errors
    if (value === '' && document.querySelector('form[method="post"]')) {
      input.value = ' '; // A space as the minimum
    }
  }

  // Extracts information about the current tag based on the cursor position
  getCurrentTagInfo(input) {
    const value = input.value;
    const cursorPos = input.selectionStart;
    
    let startPos = cursorPos;
    while (startPos > 0 && value.charAt(startPos - 1) !== ',') {
      startPos--;
    }
    
    let endPos = cursorPos;
    while (endPos < value.length && value.charAt(endPos) !== ',') {
      endPos++;
    }
    
    const currentTag = value.substring(startPos, endPos).trim();
    
    return {
      currentTag,
      startPos,
      endPos
    };
  }
}