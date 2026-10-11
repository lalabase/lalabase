# frozen_string_literal: true

# Resolves the active system functions for a specific ticket.
#
# Example:
#   Attribute "Priorität" has option "Hoch" with system_functions: ["high_priority"]
#   Ticket has custom_attributes: { "priority" => "Hoch" }
#   → Resolver returns Set["high_priority"]
#   → ticket.has_system_function?('high_priority') → true
#
# Iterates over all select/multiselect attributes of the project,
# looks up the ticket's current value, and collects the associated
# system functions. The result is cached per ticket instance.
module SystemFunctions
  class Resolver
    OPTION_FIELD_TYPES = %w[select multiselect].freeze

    def initialize(ticket)
      @ticket = ticket
    end

    # Set of active system functions (Set<String>)
    def active_functions
      @active_functions ||= compute_active_functions
    end

    # Checks whether a specific function is active
    def has?(function_key)
      active_functions.include?(function_key.to_s)
    end

    private

    def compute_active_functions
      result = Set.new

      option_definitions.each do |attr_def|
        current_value = @ticket.get_custom_attribute(attr_def.name)
        next if current_value.blank?

        functions = functions_for_value(attr_def, current_value)
        result.merge(functions)
      end

      result
    end

    # Only attributes with options (select/multiselect), typically 2-5 of them
    def option_definitions
      @ticket.attribute_definitions.select { |ad| OPTION_FIELD_TYPES.include?(ad.field_type) }
    end

    # Determines the system_functions for an attribute's current value
    def functions_for_value(attr_def, current_value)
      if attr_def.field_type == 'multiselect' && current_value.is_a?(Array)
        current_value.flat_map { |v| attr_def.system_functions_for(v) }
      else
        attr_def.system_functions_for(current_value)
      end
    end
  end
end
