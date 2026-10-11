# frozen_string_literal: true

# == System Functions: bridge between freely definable options and fixed app logic
#
# Motivation:
#   Attribute options (e.g. status "New", priority "High") are freely definable
#   per project. The app, however, needs fixed anchor points for logic such as
#   highlighting, filtering, or icons. System functions solve this problem.
#
# Concept:
#   1. User creates the attribute "Priority" with options "Low", "Medium", "High"
#   2. In the admin editor, they assign the system function :high_priority to the option "High"
#   3. On the ticket: ticket.has_system_function?('high_priority') → true/false
#   4. Views/services use this for CSS classes, badges, scopes, etc.
#
# Architecture:
#   Registry (this file)       → Defines all available functions (purely semantic)
#   TicketAttributeDefinition  → Stores the mapping option → functions (JSONB)
#   Resolver                   → Resolves the active functions for a concrete ticket
#   CustomAttributable         → Thin delegation: ticket.has_system_function?(key)
#
# This registry is purely semantic — NO CSS classes or presentation logic.
# Colors/styles belong in TicketColorMap or the view layer.
module SystemFunctions
  module Registry
    # --- Status functions ---
    IS_BACKLOG     = 'is_backlog'
    IS_NEW         = 'is_new'
    IS_OPEN        = 'is_open'
    IS_IN_PROGRESS = 'is_in_progress'
    IS_COMPLETED   = 'is_completed'
    IS_CLOSED      = 'is_closed'

    # --- Priority functions ---
    HIGH_PRIORITY  = 'high_priority'

    # --- Display functions ---
    HIGHLIGHT_CONTAINER = 'highlight_container'

    # Grouping by category for the form UI
    FUNCTION_CATEGORIES = {
      'status' => {
        label_de: 'Status',
        label_en: 'Status',
        functions: [
          { key: IS_BACKLOG, label_de: 'Backlog', label_en: 'Backlog', icon: 'inbox-fill' },
          { key: IS_NEW, label_de: 'Neu', label_en: 'New', icon: 'star' },
          { key: IS_OPEN, label_de: 'Offen', label_en: 'Open', icon: 'inbox' },
          { key: IS_IN_PROGRESS, label_de: 'In Bearbeitung', label_en: 'In Progress', icon: 'arrow-repeat' },
          { key: IS_COMPLETED, label_de: 'Erledigt', label_en: 'Completed', icon: 'check-circle' },
          { key: IS_CLOSED, label_de: 'Geschlossen', label_en: 'Closed', icon: 'x-circle' }
        ]
      },
      'priority' => {
        label_de: 'Priorität',
        label_en: 'Priority',
        functions: [
          { key: HIGH_PRIORITY, label_de: 'Hohe Priorität', label_en: 'High Priority', icon: 'exclamation-triangle' }
        ]
      },
      'display' => {
        label_de: 'Anzeige',
        label_en: 'Display',
        functions: [
          { key: HIGHLIGHT_CONTAINER, label_de: 'Container hervorheben', label_en: 'Highlight Container', icon: 'eye' }
        ]
      }
    }.freeze

    # The status functions in their fixed order: what a status means, for readers that
    # must not guess it from the status name.
    STATUS_FUNCTIONS = FUNCTION_CATEGORIES['status'][:functions].map { |f| f[:key] }.freeze

    # Flat array of all valid keys for validation
    ALL_FUNCTIONS = FUNCTION_CATEGORIES.values.flat_map { |cat| cat[:functions].map { |f| f[:key] } }.freeze

    # Checks whether a key is valid
    def self.valid?(key)
      ALL_FUNCTIONS.include?(key.to_s)
    end

    # Label for a key in a locale
    def self.label_for(key, locale = I18n.locale)
      key_str = key.to_s
      label_key = locale.to_s.start_with?('de') ? :label_de : :label_en

      FUNCTION_CATEGORIES.each_value do |category|
        func = category[:functions].find { |f| f[:key] == key_str }
        return func[label_key] if func
      end

      nil
    end

    # Icon for a key
    def self.icon_for(key)
      key_str = key.to_s

      FUNCTION_CATEGORIES.each_value do |category|
        func = category[:functions].find { |f| f[:key] == key_str }
        return func[:icon] if func
      end

      nil
    end

    # Category for a key
    def self.category_for(key)
      key_str = key.to_s

      FUNCTION_CATEGORIES.each do |cat_key, category|
        return cat_key if category[:functions].any? { |f| f[:key] == key_str }
      end

      nil
    end
  end
end
