# frozen_string_literal: true

module SmartFolders
  module Filters
    class NumberFilter < BaseFilter
      include SmartFolders::Operators

      SINGLE_VALUE_OPERATORS = [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN].freeze

      # @param query [ActiveRecord::Relation] The current query for a model type
      # @param item_type [String] The name of the model ('TimeSession', 'Ticket', etc.)
      # @return [ActiveRecord::Relation] The modified query with the number filter condition
      def apply(query, item_type)
        column = safe_column_name(query, item_type)
        return query unless column

        apply_operator(query, column)
      rescue ArgumentError, TypeError => e
        Rails.logger.error "Invalid number format for rule #{rule.id}: '#{rule.value}'. Error: #{e.message}"
        query.none
      end

      private

      def apply_operator(query, column)
        table = arel_table(query)

        case rule.operator
        when EQUALS
          query.where(table[column].eq(parse_number(rule.value)))
        when NOT_EQUALS
          # NULL values count as "not equal"
          num = parse_number(rule.value)
          query.where(table[column].not_eq(num).or(table[column].eq(nil)))
        when GREATER_THAN
          query.where(table[column].gt(parse_number(rule.value)))
        when LESS_THAN
          query.where(table[column].lt(parse_number(rule.value)))
        when BETWEEN
          min_val, max_val = parse_number_range(rule.value)
          query.where(table[column].between(min_val..max_val))
        else
          Rails.logger.warn "Unsupported number operator '#{rule.operator}' for rule #{rule.id}. Skipping rule."
          query
        end
      end
    end
  end
end
