# frozen_string_literal: true

module SmartFolders
  module Filters
    # Filter for dynamic custom attributes from the JSONB field
    class CustomAttributeFilter < BaseFilter
      include SmartFolders::Operators

      VALUELESS_OPERATORS = [IS_EMPTY, IS_BLANK, IS_NOT_EMPTY, IS_NOT_BLANK, IS_TRUE, IS, IS_FALSE, IS_NOT].freeze

      def apply(query, item_type)
        return query unless item_type == 'Ticket'

        attribute_name = extract_attribute_name
        return query unless attribute_name

        return query if requires_value? && rule.value.nil?

        apply_operator(query, attribute_name)
      end

      private

      def requires_value?
        !VALUELESS_OPERATORS.include?(rule.operator)
      end

      def apply_operator(query, attr)
        table = query.table_name

        case rule.operator
        when EQUALS       then apply_containment(query, table, attr)
        when NOT_EQUALS   then apply_not_containment(query, table, attr)
        when CONTAINS     then apply_text_match(query, table, attr, "%#{sanitize_for_like(rule.value)}%")
        when NOT_CONTAINS then apply_text_not_match(query, table, attr, "%#{sanitize_for_like(rule.value)}%")
        when STARTS_WITH  then apply_text_match(query, table, attr, "#{sanitize_for_like(rule.value)}%")
        when ENDS_WITH    then apply_text_match(query, table, attr, "%#{sanitize_for_like(rule.value)}")
        when GREATER_THAN then apply_numeric_comparison(query, table, attr, '>')
        when LESS_THAN    then apply_numeric_comparison(query, table, attr, '<')
        when BETWEEN      then apply_numeric_between(query, table, attr)
        when IS_EMPTY, IS_BLANK then apply_presence(query, table, attr, empty: true)
        when IS_NOT_EMPTY, IS_NOT_BLANK then apply_presence(query, table, attr, empty: false)
        when IS_TRUE, IS then apply_boolean(query, table, attr, true)
        when IS_FALSE, IS_NOT then apply_boolean(query, table, attr, false)
        when IN_LIST      then apply_list(query, table, attr, negate: false)
        when NOT_IN_LIST  then apply_list(query, table, attr, negate: true)
        else
          Rails.logger.warn "CustomAttributeFilter: Unknown operator '#{rule.operator}' for attribute '#{attr}'"
          query
        end
      end

      # --- Containment ---

      def apply_containment(query, table, attr)
        query.where("#{table}.custom_attributes @> ?", { attr => rule.value }.to_json)
      end

      def apply_not_containment(query, table, attr)
        query.where("NOT (#{table}.custom_attributes @> ?) OR #{table}.custom_attributes->? IS NULL",
                    { attr => rule.value }.to_json, attr)
      end

      # --- Text / ILIKE ---

      def apply_text_match(query, table, attr, pattern)
        query.where("#{table}.custom_attributes->>? ILIKE ?", attr, pattern)
      end

      def apply_text_not_match(query, table, attr, pattern)
        query.where("#{table}.custom_attributes->>? NOT ILIKE ? OR #{table}.custom_attributes->? IS NULL",
                    attr, pattern, attr)
      end

      # --- Numeric ---

      def apply_numeric_comparison(query, table, attr, operator)
        query.where("(#{table}.custom_attributes->>?)::numeric #{operator} ?", attr, rule.value.to_f)
      end

      def apply_numeric_between(query, table, attr)
        min, max = parse_number_range(rule.value)
        query.where("(#{table}.custom_attributes->>?)::numeric BETWEEN ? AND ?", attr, min, max)
      rescue ArgumentError => e
        Rails.logger.warn "CustomAttributeFilter: Invalid between value '#{rule.value}' for attribute '#{attr}': #{e.message}"
        query
      end

      # --- Presence ---

      def apply_presence(query, table, attr, empty:)
        if empty
          query.where("#{table}.custom_attributes->? IS NULL OR #{table}.custom_attributes->>? = ''", attr, attr)
        else
          query.where("#{table}.custom_attributes->? IS NOT NULL AND #{table}.custom_attributes->>? != ''", attr, attr)
        end
      end

      # --- Boolean ---

      def apply_boolean(query, table, attr, bool_value)
        query.where("#{table}.custom_attributes @> ?", { attr => bool_value }.to_json)
      end

      # --- List ---

      def apply_list(query, table, attr, negate:)
        values = rule.value.split(',').map(&:strip)
        joiner = negate ? ' AND ' : ' OR '
        prefix = negate ? 'NOT ' : ''

        conditions = values.map { |_| "#{prefix}(#{table}.custom_attributes @> ?)" }
        json_values = values.map { |val| { attr => val }.to_json }
        query.where(conditions.join(joiner), *json_values)
      end

      # --- Helpers ---

      def extract_attribute_name
        return nil unless rule.field.start_with?('custom_')

        rule.field.delete_prefix('custom_')
      end

      def sanitize_for_like(value)
        value.to_s.gsub(/[\\%_]/) { |char| "\\#{char}" }
      end
    end
  end
end
