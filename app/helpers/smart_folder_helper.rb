# frozen_string_literal: true

# Helper for smart folder functionality
module SmartFolderHelper
  # Type-scoped form title ("Wissens-Filter bearbeiten", "Neuer Ticket-Filter").
  # Falls back to the generic title for 'All', unknown or missing types.
  # @param mode [Symbol] :edit or :new
  # @param target_type [String, nil] a SmartFolder::SUPPORTED_OBJECT_TYPES key
  def smart_folder_form_title(mode, target_type)
    base = t(mode == :edit ? 'smart_folders.edit_title' : 'smart_folders.new')
    return base unless SmartFolder::SUPPORTED_OBJECT_TYPES.key?(target_type)

    t("smart_folders.#{mode}_title_by_type.#{target_type}", default: base)
  end

  # Generates options for the field dropdown in the form
  # @param target_type [String] The target type for which the fields should be filtered ('Note', 'Ticket', etc.)
  # @param organisation [Organisation] The organisation for custom attributes
  # @return [Array<Hash>] An array of hashes with field options
  def available_field_options(target_type = nil, organisation = nil, project: nil, accessible_project_ids: nil)
    target_type ||= 'All'
    organisation ||= @current_organisation

    # Fetch extended configuration with custom attributes (project-specific when possible)
    field_config = if organisation
                     SmartFolderRule.field_config_with_custom_attributes(organisation, project, accessible_project_ids: accessible_project_ids)
                   else
                     SmartFolderRule.field_config
                   end

    # Standard fields
    standard_options = []
    custom_options = []

    target_types = target_type == 'All' ? SmartFolder::ALL_OBJECT_TYPES : [target_type]
    field_config.each do |field, config|
      # Check whether the field is applicable to the object type
      next if (config[:applicable_types] & target_types).empty?
      next if config[:without_project_only] && project

      option = {
        value: field,
        label: I18n.t("smart_folders.fields.#{field}", default: config[:description] || field.humanize),
        icon: config[:icon], # For display in the frontend
        applicable_types: config[:applicable_types], # For client-side filtering
        value_type: config[:value_type], # What kind of value is expected
        reference_model: config[:reference_model],
        custom: config[:custom] || false
      }

      if config[:custom]
        custom_options << option
      else
        standard_options << option
      end
    end

    # Sort both arrays by label
    standard_options.sort_by! { |option| option[:label] }
    custom_options.sort_by! { |option| option[:label] }

    # Combine: standard fields first, then custom attributes
    standard_options + custom_options
  end

  # Generates operators for a specific field
  # @param field [String] The field name for which the operators should be returned
  # @param organisation [Organisation] The organisation for custom attributes
  # @return [Array<Hash>] An array of hashes with operator options
  def available_operator_options(field, organisation = nil, project: nil)
    return [] unless field.present?

    organisation ||= @current_organisation

    # Use extended configuration for custom attributes (project-specific when possible)
    field_config = organisation ? SmartFolderRule.field_config_with_custom_attributes(organisation, project) : SmartFolderRule.field_config
    config = field_config[field]

    return [] unless config && config[:operators]

    config[:operators].map do |op|
      {
        value: op,
        label: SmartFolderRule.operator_label(field, op)
      }
    end
  end

  # Decode stored participant sets using the same normalization as their filters.
  def smart_folder_reference_set_values(field, value)
    values = begin
      JSON.parse(value.to_s)
    rescue JSON::ParserError
      [value.to_s]
    end
    values = Array(values).map(&:to_s).reject(&:blank?)
    values = values.map { |name| MeetingParticipant.normalize_name(name) } if field == 'participant'
    values.uniq
  end

  # Loads reference options for a specific field
  # @param field [String] The field name for which the reference options should be loaded
  # @param organisation [Organisation] The current organisation
  # @param search_term [String] Optional search term to filter the results
  # @return [Array<Hash>] An array of hashes with reference options
  def available_reference_options(field, organisation, search_term = nil, project: nil, accessible_project_ids: nil, area: :tickets)
    # Use extended configuration for custom attributes (project-specific when possible)
    field_config = if organisation
                     SmartFolderRule.field_config_with_custom_attributes(organisation, project, accessible_project_ids: accessible_project_ids)
                   else
                     SmartFolderRule.field_config
                   end
    config = field_config[field]

    if field == 'participant'
      meetings = policy_scope(Meeting).where(organisation_id: organisation.id)
      meetings = meetings.where(project_id: project.id) if project
      meetings = meetings.where(project_id: accessible_project_ids) unless accessible_project_ids.nil?
      return MeetingParticipant.distinct_names_for_meetings(meetings).filter_map do |label, value|
        { value: value, label: label } if search_term.blank? || label.downcase.include?(search_term.downcase)
      end
    end

    # Special handling for custom attributes with select/multiselect fields
    if config && config[:custom] && config[:attribute_definition]
      attr_def = config[:attribute_definition]
      if %w[select multiselect].include?(attr_def.field_type)
        # Fetch options from the attribute definition
        allowed_values = attr_def.allowed_values
        return allowed_values.map do |opt|
          label = opt['labels']&.dig(I18n.locale.to_s) ||
                  opt['labels']&.dig(I18n.default_locale.to_s) ||
                  opt['value']
          { value: opt['value'], label: label }
        end
      end
    end

    return [] unless config && config[:value_type] == :reference && config[:reference_model]

    # Special case for tags
    if field == 'tag'
      # Fetch all tags of the organisation
      tags = Tag.where(organisation_id: organisation.id)
                .order(:name)
                .pluck(:name)

      # Filter for search functionality
      tags = tags.select { |tag| tag.downcase.include?(search_term.downcase) } if search_term.present?

      # Format as expected
      return tags.map { |tag| { value: tag, label: tag } }
    end

    begin
      model_class = config[:reference_model].constantize
      # Build base query, restricted to the current organisation when possible
      base_scope = model_class.all
      base_scope = base_scope.where(organisation_id: organisation.id) if model_class.column_names.include?('organisation_id')

      # Restrict references to accessible projects. Scope user references (e.g.
      # assignee) to the people visible to the current user — otherwise the
      # reference list leaks names/emails of users from other projects (even other orgs).
      # User has no organisation_id: visibility also applies without explicit project IDs.
      if model_class == User || !accessible_project_ids.nil?
        case model_class.name
        when 'Project' then base_scope = base_scope.where(id: accessible_project_ids)
        when 'Ticket'  then base_scope = base_scope.where(project_id: accessible_project_ids)
        when 'User'
          base_scope = base_scope.where(
            id: AccessCheck::ProjectAccessService.users_visible_to(current_user, organisation, area: area).select(:id)
          )
        end
      end

      # Optional: sort the options sensibly
      sort_column = %i[name title email].find { |col| model_class.column_names.include?(col.to_s) } || model_class.primary_key
      records = base_scope.order(sort_column)

      # Filter by search term, if one is present
      records = records.where('name ILIKE ?', "%#{search_term}%") if search_term.present? && model_class.column_names.include?('name')
      records = records.limit(50) # Limit for performance

      # Format options
      records.map do |record|
        label = case model_class.name
                when 'User' then record.display_name
                when 'Tag' then record.name
                else record.try(:display_name) || record.try(:name) || record.try(:title) || "#{model_class.name} #{record.id}"
                end
        { value: record.id, label: label }
      end
    rescue NameError => e
      Rails.logger.error("Reference model '#{config[:reference_model]}' not found: #{e.message}")
      []
    rescue StandardError => e
      Rails.logger.error("Error loading reference options: #{e.message}")
      []
    end
  end
end
