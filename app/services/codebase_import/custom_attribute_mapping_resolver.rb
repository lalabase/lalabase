# frozen_string_literal: true

module CodebaseImport
  class CustomAttributeMappingResolver
    attr_reader :organisation, :attribute_type, :mappings, :custom_attribute_service

    def initialize(organisation, attribute_type, mappings, custom_attribute_service)
      @organisation = organisation
      @attribute_type = attribute_type # 'status' or 'priority'
      @mappings = mappings
      @custom_attribute_service = custom_attribute_service
    end

    # Resolves the mappings and returns a hash with Codebase value => custom attribute value
    def resolve
      resolved = {}

      mappings.each do |codebase_name, mapping_config|
        action = mapping_config['action']

        resolved_value = case action
                         when 'create'
                           create_custom_attribute_value(codebase_name)
                         when 'map'
                           map_to_existing_value(mapping_config['target_value'])
                         else
                           raise TicketImporter::MappingError, I18n.t('services.codebase_import.custom_attribute_mapping.unknown_action', type: attribute_type, name: codebase_name, action: action)
                         end

        resolved[codebase_name] = resolved_value
      end

      resolved
    end

    private

    def create_custom_attribute_value(name)
      # Adds the new value to allowed_values
      custom_attribute_service.add_allowed_value(attribute_type, name)
      # Returns the value itself, since we store it directly in custom_attributes
      name
    end

    def map_to_existing_value(target_value)
      # Handle empty target values
      raise TicketImporter::MappingError, I18n.t('services.codebase_import.custom_attribute_mapping.target_blank', type: attribute_type) if target_value.blank?

      # Validates that the target value exists
      attribute_def = find_attribute_definition

      if attribute_def
        allowed_values = attribute_def.allowed_values || []
        unless allowed_values.any? { |opt| opt['value'] == target_value }
          # Add the value automatically if it does not exist
          Rails.logger.debug "CustomAttributeMappingResolver: Adding new value '#{target_value}' to #{attribute_type}"
          custom_attribute_service.add_allowed_value(attribute_type, target_value)
        end
      end

      target_value
    end

    def find_attribute_definition
      TicketAttributeDefinition.joins(:project)
                               .where(projects: { organisation_id: organisation.id })
                               .find_by(name: attribute_type)
    end
  end
end
