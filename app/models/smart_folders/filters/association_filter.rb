# frozen_string_literal: true

module SmartFolders
  module Filters
    # Filter for simple associations via foreign keys (e.g. status, priority).
    # Expects the rule value (rule.value) to be the ID of the associated object.
    class AssociationFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, item_type)
        column = safe_column_name(query, item_type)
        return query unless column

        table = arel_table(query)
        value = rule.value

        return handle_blank_value(query, table, column) if value.blank?

        case rule.operator
        when EQUALS
          query.where(table[column].eq(value))
        when NOT_EQUALS
          query.where(table[column].not_eq(value).or(table[column].eq(nil)))
        else
          Rails.logger.warn "Unsupported association operator '#{rule.operator}' for rule #{rule.id}. Skipping rule."
          query
        end
      end

      private

      def handle_blank_value(query, table, column)
        case rule.operator
        when EQUALS
          query.none
        when NOT_EQUALS
          query.where(table[column].not_eq(nil))
        else
          query
        end
      end
    end
  end
end
