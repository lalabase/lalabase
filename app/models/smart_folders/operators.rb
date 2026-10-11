# frozen_string_literal: true

# app/models/smart_folders/operators.rb
# Single source of truth for the smart-folder rule operator vocabulary. The values are persisted
# verbatim in smart_folder_rules.operator and interpolated into i18n keys
# ("smart_folders.operators.#{op}") — changing a value silently breaks stored rules and labels.
#
# Two producers feed this vocabulary, and both live in SmartFolderRule:
#   * .field_config              — the static, built-in fields (title, tag, created_at, …)
#   * .operators_for_field_type  — the dynamic fields derived from custom attributes
# Consumers are the filter classes under filters/, the value validator, and the smart-folder
# services. Include this module and reference the constants unqualified.
#
# Deliberate duplication: the Stimulus rule builder keeps its own copy of the RELATIVE_DATE and
# MULTI_TAG groups (app/javascript/controllers/smart_folder_form_controller.js) — Ruby constants do
# not cross that boundary. Both spots carry a back-reference; change them together.
#
# NOT owned here: the relative deadline operators (overdue, due_today, …). They come from
# Ticket::DUE_DATE_PRESET_KEYS via SmartFolderRule::DEADLINE_RELATIVE_OPERATORS so the smart folder
# and the FilterBar quick-filter can never drift apart.
module SmartFolders
  module Operators
    # Equality and text matching
    EQUALS = 'equals'
    NOT_EQUALS = 'not_equals'
    CONTAINS = 'contains'
    NOT_CONTAINS = 'not_contains'
    STARTS_WITH = 'starts_with'
    ENDS_WITH = 'ends_with'

    # Numeric and date comparison
    GREATER_THAN = 'greater_than'
    LESS_THAN = 'less_than'
    BEFORE = 'before'
    AFTER = 'after'
    BETWEEN = 'between'

    # Relative date windows (value = a number of days)
    WITHIN_DAYS = 'within_days'
    IN_THE_LAST_DAYS = 'in_the_last_days'

    # Tags
    HAS = 'has'
    NOT_HAS = 'not_has'
    HAS_ANY_OF = 'has_any_of'
    HAS_ALL_OF = 'has_all_of'

    # Booleans. IS/IS_NOT are used by the built-in boolean fields, IS_TRUE/IS_FALSE by custom
    # checkbox attributes — the custom-attribute filter treats each pair as synonymous.
    IS = 'is'
    IS_NOT = 'is_not'
    IS_TRUE = 'is_true'
    IS_FALSE = 'is_false'

    # Presence (valueless)
    IS_EMPTY = 'is_empty'
    IS_NOT_EMPTY = 'is_not_empty'

    # Multi-value selection on custom select/multiselect attributes (value = comma separated)
    IN_LIST = 'in_list'
    NOT_IN_LIST = 'not_in_list'

    # Accept-only aliases of IS_EMPTY/IS_NOT_EMPTY. Neither producer lists them, so the rule
    # builder never offers them; the custom attribute filters merely tolerate them defensively
    # on stored rules.
    IS_BLANK = 'is_blank'
    IS_NOT_BLANK = 'is_not_blank'

    # Named groups for operator sets that are handled together in more than one place — the
    # coupling was previously implicit in duplicated `when` clauses.
    RELATIVE_DATE = [WITHIN_DAYS, IN_THE_LAST_DAYS].freeze
    MULTI_TAG = [HAS_ANY_OF, HAS_ALL_OF].freeze
    # Select/multiselect membership: the value is a comma-separated list, which drives both the
    # allowed-value validation and the checkbox-list input in the rule builder.
    LIST_MEMBERSHIP = [IN_LIST, NOT_IN_LIST].freeze
  end
end
