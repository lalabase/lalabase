# frozen_string_literal: true

# app/models/smart_folders/filters/base_filter.rb
# (This code was already created in step 1 and remains unchanged)
module SmartFolders
  module Filters
    # Base class for all filter strategies.
    # Every subclass must implement the `apply` method.
    class BaseFilter
      attr_reader :rule

      def initialize(rule)
        @rule = rule
      end

      # This method is overridden by subclasses to apply the
      # filter logic to an ActiveRecord::Relation.
      # @param query [ActiveRecord::Relation] The current query
      # @param item_type [String] The name of the model ('Note', 'Ticket', etc.)
      # @return [ActiveRecord::Relation] The modified query
      def apply(query, _item_type)
        # Default implementation: returns the query unchanged.
        # In the next steps this is overridden by the subclasses.
        query
      end

      protected

      # Helper method to get the correct field name for the model
      # (accounts for field_map from the rule configuration).
      def get_field_name(item_type)
        # Calls the method on the rule
        rule.get_field_name(item_type)
      end

      # Helper method for accessing the Arel table of the query model
      def arel_table(query)
        query.model.arel_table
      end

      # Helper method to safely retrieve the column name
      def safe_column_name(query, item_type)
        column = get_field_name(item_type)
        if column && query.model.column_names.include?(column.to_s)
          column.to_sym
        else
          Rails.logger.warn "SmartFolder Filter Warning: Column '#{column || 'nil'}' not found for model #{query.model.name}."
          nil
        end
      end

      # Converts heterogeneous truthy values (String/Boolean/Integer) into a boolean.
      # Used in BooleanFilter, HasTimeSessionsFilter, etc.
      TRUTHY_VALUES = ['true', true, '1', 1].freeze

      def truthy_value?(value)
        TRUTHY_VALUES.include?(value)
      end

      RANGE_SEPARATOR = ','

      def parse_number(number_string)
        Float(number_string.to_s.tr(',', '.'))
      end

      def parse_number_range(range_string)
        numbers = range_string.to_s.split(RANGE_SEPARATOR).map { |n| parse_number(n.strip) }
        raise ArgumentError, 'Range requires exactly two numbers' unless numbers.length == 2

        numbers.sort
      end
    end
  end
end
