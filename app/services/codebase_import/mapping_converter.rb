# frozen_string_literal: true

module CodebaseImport
  # Converts old ID-based mappings to new value-based mappings for custom attributes
  class MappingConverter
    attr_reader :organisation

    def initialize(organisation)
      @organisation = organisation
    end

    # Converts status mappings from target_id to target_value
    def convert_status_mappings(old_mappings)
      convert_mappings(old_mappings, 'status')
    end

    # Converts priority mappings from target_id to target_value
    def convert_priority_mappings(old_mappings)
      convert_mappings(old_mappings, 'priority')
    end

    private

    def convert_mappings(old_mappings, type)
      return {} unless old_mappings.is_a?(Hash)

      converted = {}

      old_mappings.each do |codebase_name, mapping_config|
        action = mapping_config['action']

        converted[codebase_name] = case action
                                   when 'map'
                                     # Convert from target_id to target_value
                                     target_id = mapping_config['target_id']
                                     if target_id.present?
                                       target_value = find_value_by_id(target_id, type)
                                       { 'action' => 'map', 'target_value' => target_value }
                                     else
                                       # If no target_id is present, treat as create
                                       { 'action' => 'create' }
                                     end
                                   when 'create'
                                     mapping_config
                                   else
                                     # Keep unknown action
                                     mapping_config
                                   end
      end

      converted
    end

    def find_value_by_id(id, type)
      # DEPRECATED: Old tables were removed - fallback to ID
      # TODO: This method can be removed once all imports are switched over to CustomAttributes

      # Since the ticket_statuses and ticket_priorities tables were removed,
      # we use the ID directly as the fallback value
      Rails.logger.warn "MappingConverter: Old #{type} tables not available, using ID '#{id}' as value"

      # Fallback to ID as string
      id.to_s
    end
  end
end
