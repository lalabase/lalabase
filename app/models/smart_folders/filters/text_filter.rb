# frozen_string_literal: true

# app/models/smart_folders/filters/text_filter.rb
module SmartFolders
  module Filters
    class TextFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, item_type)
        column = safe_column_name(query, item_type)
        return query.none unless column

        arel = arel_table(query)
        text_value = rule.value.to_s
        like_value = ActiveRecord::Base.sanitize_sql_like(text_value)

        apply_operator(query, arel, column, text_value, like_value)
      end

      private

      def apply_operator(query, arel, column, text_value, like_value)
        case rule.operator
        when CONTAINS
          query.where(arel[column].matches("%#{like_value}%"))
        when NOT_CONTAINS
          query.where(arel[column].does_not_match("%#{like_value}%").or(arel[column].eq(nil)))
        when EQUALS
          query.where(lower(arel[column]).eq(Arel::Nodes.build_quoted(text_value.downcase)))
        when NOT_EQUALS
          query.where(lower(arel[column]).not_eq(Arel::Nodes.build_quoted(text_value.downcase)).or(arel[column].eq(nil)))
        when STARTS_WITH
          query.where(arel[column].matches("#{like_value}%"))
        when ENDS_WITH
          query.where(arel[column].matches("%#{like_value}"))
        else
          Rails.logger.warn "Unsupported text operator '#{rule.operator}' for rule #{rule.id}"
          query
        end
      end

      def lower(node)
        Arel::Nodes::NamedFunction.new('LOWER', [node])
      end
    end
  end
end
