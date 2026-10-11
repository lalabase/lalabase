# frozen_string_literal: true

# app/services/smart_folder_rule_factory.rb
class SmartFolderRuleFactory
  include SmartFolders::Operators

  # Creates and validates SmartFolderRule objects based on raw data.
  # Returns an unsaved but validated rule instance.
  #
  # Optional keyword args for batch performance:
  #   field_config_map: precomputed field config (avoids N+1 on ticket_attribute_definitions)
  #   preloaded_references: { 'User' => { id => record } } (avoids N+1 on reference lookups)
  def self.build(smart_folder_rule_group, field, operator, value, position = nil,
                 field_config_map: nil, preloaded_references: nil)
    # Fetch organisation and project for custom attributes
    smart_folder = smart_folder_rule_group&.smart_folder
    organisation = smart_folder&.organisation
    project = smart_folder&.project

    # Use the passed-in or freshly computed configuration
    field_config = field_config_map ||
                   (organisation ? SmartFolderRule.field_config_with_custom_attributes(organisation, project) : SmartFolderRule.field_config)
    config = field_config[field]

    raise ArgumentError, I18n.t('services.smart_folder_rule_factory.invalid_field', field: field) unless config

    raise ArgumentError, I18n.t('services.smart_folder_rule_factory.invalid_operator', operator: operator, field: field, valid_operators: config[:operators]&.join(', ') || 'keine') unless config[:operators]&.include?(operator)

    # Pre-process and format the value (e.g. normalize a date)
    processed_value = process_value(value, config[:value_type], operator)
    display_value = format_display_value(processed_value, config[:value_type], operator, config,
                                         preloaded_references: preloaded_references)

    # Create a new rule instance (not yet saved)
    rule = SmartFolderRule.new(
      smart_folder_rule_group: smart_folder_rule_group,
      field: field,
      operator: operator,
      value: processed_value,
      display_value: display_value,
      position: position # May be overwritten by a callback if nil
    )

    # Propagate preloaded caches to avoid N+1 in validations/callbacks
    rule.cached_field_config_data = field_config
    rule.preloaded_references = preloaded_references if preloaded_references

    rule
  end

  # --- Private Helpers ---

  # Processes and formats the raw value depending on type and operator
  private_class_method def self.process_value(raw_value, value_type, operator)
    # Return nil if the raw value is blank (blank? checks for nil, "", " ", [], {})
    return nil if raw_value.blank?

    # Convert to string for most operations, except for boolean/arrays
    value_str = raw_value.is_a?(Array) || raw_value.is_a?(TrueClass) || raw_value.is_a?(FalseClass) ? raw_value : raw_value.to_s.strip

    case value_type
    when :date
      process_date_value(value_str, operator)
    when :number
      process_number_value(value_str, operator)
    when :boolean
      process_boolean_value(raw_value) # Pass the raw value here
    when :reference
      # For references, normalize commas if needed
      value_str.is_a?(Array) ? value_str.map(&:to_s).map(&:strip).join(',') : value_str
    when :text
      value_str # Simply the trimmed string
    else
      value_str # Fallback
    end
  end

  # Processes and normalizes date values
  private_class_method def self.process_date_value(value_str, operator)
    case operator
    when BETWEEN
      # Supports both arrays and comma-separated strings
      dates = value_str.is_a?(Array) ? value_str : value_str.to_s.split(',')

      # Format each date and remove invalid ones
      formatted_dates = dates.map { |d| format_date(d) }.compact

      # Handle the various cases depending on the number of valid dates
      if formatted_dates.length == 2
        # Two dates: normal range
        start_date = Date.parse(formatted_dates[0])
        end_date = Date.parse(formatted_dates[1])

        # Ensure that start <= end
        start_date, end_date = end_date, start_date if start_date > end_date

        "#{start_date.iso8601},#{end_date.iso8601}"
      elsif formatted_dates.length == 1
        # One date: use it for both start and end (same day)
        date = Date.parse(formatted_dates[0])
        "#{date.iso8601},#{date.iso8601}"
      else
        # No valid dates
        Rails.logger.warn "No valid dates found in between operator for value: #{value_str}"
        nil
      end
    when *SmartFolders::DatePresets::KEYS
      # Valueless: the preset is the operator, a stray value is dropped
      nil
    when *RELATIVE_DATE
      # Convert to integer and ensure it is positive
      days = begin
        Integer(value_str.to_s.strip)
      rescue ArgumentError, TypeError
        0 # Fallback on error
      end

      # Positive number or fall back to 1 day
      days > 0 ? days.to_s : '1'
    else
      # Normalize a single date
      format_date(value_str)
    end
  end

  # Processes number values
  private_class_method def self.process_number_value(value_str, operator)
    case operator
    when BETWEEN
      numbers = value_str.is_a?(Array) ? value_str : value_str.to_s.split(',')
      parsed_numbers = numbers.map { |n| parse_float(n) }.compact

      if parsed_numbers.length == 2
        min_val = parsed_numbers.min
        max_val = parsed_numbers.max
        "#{min_val},#{max_val}" # Always store as float for consistency? Or keep the type?
      else
        nil # Invalid range
      end
    else
      # Parse a single number
      parsed_number = parse_float(value_str)
      parsed_number&.to_s # Store as a string
    end
  end

  # Processes boolean values (returns 'true' or 'false' as a string)
  private_class_method def self.process_boolean_value(raw_value)
    # Checks various truthy values
    is_true = ['true', '1', 1, true].include?(raw_value.to_s.downcase) || raw_value == true
    is_true.to_s # Returns "true" or "false"
  end

  # --- Formatting for display ---

  # Formats the stored value for display (e.g. in the rule editor)
  private_class_method def self.format_display_value(processed_value, value_type, operator, config = {},
                                                     preloaded_references: nil)
    return '' if processed_value.blank?

    case value_type
    when :date
      format_date_display(processed_value, operator)
    when :boolean
      processed_value.to_s == 'true' ? I18n.t('generic.yes', default: 'Ja') : I18n.t('generic.no', default: 'Nein')
    when :reference
      # Try to resolve the name of the reference
      resolve_reference_display_value(processed_value, config, preloaded_references: preloaded_references)
    when :text
      # For custom attributes with select/multiselect, the display_value equals the value
      # since we store the label values directly
      if config[:custom] && config[:attribute_definition]
        attr_def = config[:attribute_definition]
        if %w[select multiselect].include?(attr_def.field_type)
          # For custom select fields the value is already human-readable
          return processed_value.to_s
        end
      end
      processed_value.to_s
    else
      processed_value.to_s
    end
  end

  # Formats a date for display
  private_class_method def self.format_date_display(date_value_str, operator)
    case operator
    when BETWEEN
      dates = date_value_str.split(',')
      if dates.length == 2
        I18n.t('smart_folders.display.date_between',
               start_date: format_date_locale(dates[0]),
               end_date: format_date_locale(dates[1]),
               default: "vom #{format_date_locale(dates[0])} bis #{format_date_locale(dates[1])}")
      else
        date_value_str # Fallback
      end
    when *RELATIVE_DATE
      I18n.t("smart_folders.display.date_#{operator}", days: date_value_str, default: "innerhalb der letzten #{date_value_str} Tage")
    when BEFORE, AFTER, EQUALS, NOT_EQUALS
      I18n.t("smart_folders.display.date_#{operator}", date: format_date_locale(date_value_str), default: "#{operator.humanize} #{format_date_locale(date_value_str)}")
    else
      format_date_locale(date_value_str)
    end
  rescue ArgumentError
    date_value_str # Fallback on invalid format
  end

  # --- Helper methods ---

  # Tries to parse a string as a date and returns ISO 8601 (YYYY-MM-DD) or nil
  # Supports several common date formats
  private_class_method def self.format_date(date_string)
    return nil if date_string.blank?

    date_str = date_string.to_s.strip

    begin
      # ISO 8601 (YYYY-MM-DD) format - already in the correct format
      return Date.parse(date_str).iso8601 if date_str.match?(/^\d{4}-\d{2}-\d{2}$/)

      # German format (DD.MM.YYYY)
      if date_str.match?(/^\d{1,2}\.\d{1,2}\.\d{4}$/)
        day, month, year = date_str.split('.')
        return Date.new(year.to_i, month.to_i, day.to_i).iso8601
      end

      # US format (MM/DD/YYYY)
      if date_str.match?(%r{^\d{1,2}/\d{1,2}/\d{4}$})
        month, day, year = date_str.split('/')
        return Date.new(year.to_i, month.to_i, day.to_i).iso8601
      end

      # Further formats could be added here...

      # Flexible fallback with Date.parse (detection of various formats)
      parsed_date = Date.parse(date_str)
      parsed_date.iso8601
    rescue ArgumentError, TypeError
      nil
    end
  end

  # Formats a date (YYYY-MM-DD) for a more compact display (DD.MM.YY)
  private_class_method def self.format_date_locale(date_string)
    return date_string if date_string.blank?

    begin
      Date.parse(date_string).strftime('%d.%m.%y')
    rescue ArgumentError
      date_string # Fallback
    end
  end

  # Resolves reference IDs to human-readable names
  private_class_method def self.resolve_reference_display_value(processed_value, config, preloaded_references: nil)
    return processed_value.to_s if processed_value.blank? || config[:reference_model].blank?

    begin
      model_class = config[:reference_model].constantize
      record = preloaded_references&.dig(model_class.name, processed_value) ||
               model_class.find_by(id: processed_value)
      return processed_value.to_s unless record

      case model_class.name
      when 'User' then record.display_name
      else record.try(:display_name) || record.try(:name) || record.try(:title) || processed_value.to_s
      end
    rescue NameError, StandardError
      processed_value.to_s
    end
  end

  # Tries to parse a string as a float
  private_class_method def self.parse_float(number_string)
    return nil if number_string.blank?

    begin
      Float(number_string.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
