# frozen_string_literal: true

# app/models/smart_folders/validators/value_validator.rb
module SmartFolders
  module Validators
    class ValueValidator
      # Factory method for creating the right validator based on :value_type
      def self.for_field_type(value_type)
        case value_type
        when :date
          DateValidator
        when :number
          NumberValidator
        when :boolean
          BooleanValidator
        when :reference_set
          ReferenceSetValidator
        when :reference
          ReferenceValidator
        when :text
          TextValidator
        else
          # Fallback for unknown types or types without special validation
          BaseValidator
        end
      end
    end

    # --- Base validator class ---
    class BaseValidator
      include SmartFolders::Operators

      def validate(rule, field_config)
        # A field that requires a value still has valueless operators (is_empty, the relative
        # deadline presets, the date presets): SmartFolderRule.optional_value_operators is the one
        # list of them, and the rule builder reads the same list from the field_operators API.
        value_needed = field_config.fetch(:value_required, false) &&
                       !SmartFolderRule.optional_value_operators.include?(rule.operator)

        # Check whether a value is required AND it is blank.
        if value_needed && rule.value.blank?
          rule.errors.add(:value, :blank) # Default Rails :blank message
          return false
        end

        true # Valid by default if no specific checks fail
      end
    end

    # Reference sets also accept a legacy single name. Empty or malformed sets
    # must not turn a saved condition into an unrestricted query.
    class ReferenceSetValidator < BaseValidator
      def validate(rule, field_config)
        return false unless super

        values = Meetings::ParticipantFilter.rule_values(rule.value)
        return true if values.is_a?(Array) && values.any? && values.all? { |value| value.is_a?(String) && value.present? }

        rule.errors.add(:value, :blank)
        false
      rescue JSON::ParserError
        rule.errors.add(:value, :invalid)
        false
      end
    end

    # --- Validator for date fields ---
    class DateValidator < BaseValidator
      def validate(rule, field_config)
        # Run the base check first (e.g. whether a value is required)
        return false unless super

        # No further check if no value is present (and none is required)
        return true if rule.value.blank?

        case rule.operator
        when BETWEEN
          validate_date_between(rule)
        when *RELATIVE_DATE
          validate_days_number(rule)
        when *SmartFolders::DatePresets::KEYS
          true # the preset is the operator; a stray value is ignored by the filter
        else
          # For 'equals', 'not_equals', 'before', 'after'
          validate_single_date(rule)
        end
      end

      private

      def validate_date_between(rule)
        dates = rule.value.to_s.split(',')

        # Check the number of parts (1 or 2 accepted)
        if dates.length > 2
          rule.errors.add(:value, :wrong_date_count_for_between)
          return false
        end

        # Check each date individually
        parsed_dates = dates.map { |d| parse_date(d.strip) }.compact

        # Handle the various cases
        if parsed_dates.empty?
          rule.errors.add(:value, :invalid_date_format)
          return false
        elsif parsed_dates.length == 1 && dates.length == 2
          # We have two date parts, but only one could be parsed
          rule.errors.add(:value, :partial_invalid_date)
          return false
        end

        # If we have two dates, check the order
        if parsed_dates.length == 2 && parsed_dates[0] > parsed_dates[1]
          # NOTE: We do not return an error here, but allow the rule
          # The dates are processed later in the correct order
          Rails.logger.debug "User provided dates in reverse order: #{parsed_dates[0]} comes after #{parsed_dates[1]}. Will be corrected."
        end

        true
      end

      def validate_days_number(rule)
        value_str = rule.value.to_s
        unless value_str.match?(/^\d+$/)
          rule.errors.add(:value, :not_a_positive_integer)
          return false
        end

        # Optional: check a maximum value for days?
        # days = value_str.to_i
        # if days > 3650 # Example: max 10 years
        #   rule.errors.add(:value, :too_many_days, message: "Die Anzahl der Tage darf nicht zu groß sein")
        #   return false
        # end

        true
      end

      def validate_single_date(rule)
        date = parse_date(rule.value.to_s.strip)

        if date.nil?
          rule.errors.add(:value, :invalid_date_format)
          return false
        end

        true
      end

      def parse_date(date_string)
        return nil if date_string.blank?

        date_str = date_string.to_s.strip

        # Try to parse various date formats
        begin
          # ISO 8601 (YYYY-MM-DD) format
          return Date.parse(date_str) if date_str.match?(/^\d{4}-\d{2}-\d{2}$/)

          # German format (DD.MM.YYYY)
          if date_str.match?(/^\d{1,2}\.\d{1,2}\.\d{4}$/)
            day, month, year = date_str.split('.')
            return Date.new(year.to_i, month.to_i, day.to_i)
          end

          # More formats could be added here

          # Flexible fallback attempt with Date.parse
          # This allows other formats that Ruby recognizes
          Date.parse(date_str)
        rescue ArgumentError, TypeError
          nil # Return nil on error
        end
      end
    end

    # --- Validator for number fields ---
    class NumberValidator < BaseValidator
      def validate(rule, field_config)
        return false unless super
        return true if rule.value.blank? # No check if blank and not required

        case rule.operator
        when BETWEEN
          validate_number_between(rule)
        else
          validate_single_number(rule)
        end
      end

      private

      def validate_number_between(rule)
        numbers = rule.value.to_s.split(',')

        if numbers.length != 2
          rule.errors.add(:value, :wrong_number_count_for_between)
          return false
        end

        min_str = numbers[0].strip
        max_str = numbers[1].strip

        min = parse_number(min_str)
        max = parse_number(max_str)

        if min.nil? || max.nil?
          rule.errors.add(:value, :invalid_number_pair)
          return false
        end

        if min > max
          rule.errors.add(:value, :min_greater_than_max)
          return false
        end

        true
      end

      def validate_single_number(rule)
        number = parse_number(rule.value.to_s.strip)

        if number.nil?
          rule.errors.add(:value, :invalid_number_format)
          return false
        end

        true
      end

      def parse_number(number_string)
        return nil if number_string.blank?

        # Tries to convert to Float. Accepts integers and decimal numbers.
        Float(number_string)
      rescue ArgumentError, TypeError
        nil # Invalid format
      end
    end

    # --- Validator for boolean fields ---
    class BooleanValidator < BaseValidator
      VALID_BOOLEAN_VALUES = ['true', 'false', true, false, '1', '0', 1, 0].freeze

      def validate(rule, field_config)
        return false unless super
        return true if rule.value.blank? # No check if blank and not required

        # Check against a fixed list of valid values
        unless VALID_BOOLEAN_VALUES.include?(rule.value) || VALID_BOOLEAN_VALUES.include?(rule.value.to_s.downcase)
          rule.errors.add(:value, :invalid_boolean_format)
          return false
        end

        true
      end
    end

    # --- Validator for reference fields ---
    class ReferenceValidator < BaseValidator
      def validate(rule, field_config)
        return false unless super
        # No further check if no value is present (and none is required)
        # Checking existence here can be slow; optionally move it elsewhere.
        return true if rule.value.blank?

        reference_model_name = field_config[:reference_model]
        unless reference_model_name
          # This should actually be caught by the field validation
          rule.errors.add(:base, :missing_reference_model_config)
          return false
        end

        begin
          model_class = reference_model_name.constantize
        rescue NameError
          rule.errors.add(:base, :invalid_reference_model, model: reference_model_name)
          return false
        end

        # Distinguish between operators that could allow multiple IDs
        # (even though the current config only has equals/not_equals)
        if MULTI_TAG.include?(rule.operator) && model_class.respond_to?(:exists?) # 'exists?' as an indicator of an ActiveRecord model
          validate_multiple_references(rule, model_class)
        elsif model_class.respond_to?(:exists?)
          validate_single_reference(rule, model_class)
        else
          # Fallback if it is not an ActiveRecord model or exists? is not available
          rule.errors.add(:base, :cannot_validate_reference, model: reference_model_name)
          false
        end
      end

      private

      # Checks a single ID and caches the result for resolve_display_value
      def validate_single_reference(rule, model_class)
        value_str = rule.value.to_s.strip
        return false unless valid_id_format?(value_str, model_class, rule)

        record = (rule.preloaded_references.dig(model_class.name, value_str) if rule.respond_to?(:preloaded_references) && rule.preloaded_references)

        record ||= model_class.find_by(id: value_str)

        unless record
          rule.errors.add(:value, :reference_not_found, id: value_str, model: model_class.model_name.human)
          return false
        end

        # Cache for resolve_display_value to reuse without a second query
        if rule.respond_to?(:preloaded_references=)
          rule.preloaded_references ||= {}
          rule.preloaded_references[model_class.name] ||= {}
          rule.preloaded_references[model_class.name][value_str] = record
        end

        true
      end

      # Checks a comma-separated list of IDs
      def validate_multiple_references(rule, model_class)
        ids = rule.value.to_s.split(',').map(&:strip).reject(&:blank?)

        if ids.empty?
          rule.errors.add(:value, :missing_ids_for_multi_reference)
          return false
        end

        # Check the format of all IDs
        all_formats_valid = ids.all? { |id| valid_id_format?(id, model_class, rule) }
        return false unless all_formats_valid

        # SLOW operation: check the existence of all IDs.
        found_count = model_class.where(id: ids).count
        if found_count != ids.length
          missing_ids = ids - model_class.where(id: ids).pluck(:id).map(&:to_s)
          rule.errors.add(:value, :references_not_found, ids: missing_ids.join(', '), model: model_class.model_name.human)
          return false
        end

        true
      end

      # Checks the format of an ID (UUID or Integer)
      def valid_id_format?(id_string, model_class, rule)
        id_type = model_class.columns_hash['id']&.type

        case id_type
        when :uuid
          unless id_string.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
            rule.errors.add(:value, :invalid_uuid_format, id: id_string)
            return false
          end
        when :integer, :bigint
          unless id_string.match?(/^\d+$/)
            rule.errors.add(:value, :invalid_integer_id_format, id: id_string)
            return false
          end
        else
          # Unknown ID type, only check for presence
          if id_string.blank?
            rule.errors.add(:value, :blank_id)
            return false
          end
        end
        true # Format is valid
      end
    end

    # --- Validator for text fields ---
    class TextValidator < BaseValidator
      def validate(rule, field_config)
        # Run the base check (value required?)
        return false unless super

        # No further specific checks necessary for text content,
        # except possibly length restrictions, if required.
        # Example:
        # if rule.value.present? && rule.value.length > 1000
        #   rule.errors.add(:value, :too_long, count: 1000)
        #   return false
        # end

        true
      end
    end
  end
end
