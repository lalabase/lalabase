# frozen_string_literal: true

# app/models/smart_folders/filters/boolean_filter.rb
module SmartFolders
  module Filters
    # Filters by presence/absence of timestamp columns (e.g. billed_at).
    # Currently only used for the 'billed' field on TimeSession.
    # has_time_sessions is handled separately by HasTimeSessionsFilter.
    class BooleanFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, item_type)
        case rule.field
        when 'billed'
          apply_billed_status(query, item_type)
        else
          Rails.logger.warn "BooleanFilter: unhandled field '#{rule.field}' (rule #{rule.id})"
          query
        end
      end

      private

      def apply_billed_status(query, item_type)
        return query unless item_type == 'TimeSession' && query.model == TimeSession

        column = safe_column_name(query, item_type)
        return query unless column

        table = arel_table(query)
        condition = build_presence_condition(table, column)
        condition ? query.where(condition) : query
      end

      # Builds an IS NULL / IS NOT NULL condition based on operator + value.
      # value=true + operator=is     → NOT NULL (is billed)
      # value=false + operator=is    → IS NULL  (not billed)
      # value=true + operator=is_not → IS NULL
      # value=false + operator=is_not→ NOT NULL
      def build_presence_condition(table, column)
        truthy = truthy_value?(rule.value)

        case rule.operator
        when IS
          truthy ? table[column].not_eq(nil) : table[column].eq(nil)
        when IS_NOT
          truthy ? table[column].eq(nil) : table[column].not_eq(nil)
        else
          Rails.logger.warn "BooleanFilter: unsupported operator '#{rule.operator}' (rule #{rule.id})"
          nil
        end
      end
    end
  end
end
