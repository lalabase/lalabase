# frozen_string_literal: true

# app/models/smart_folders/filters/version_count_filter.rb
module SmartFolders
  module Filters
    class VersionCountFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, _item_type)
        return query unless query.model == Document

        count_value = parse_count_value
        return query.none if count_value.nil?

        version_count = DocumentVersion.arel_table[:id].count
        joined_query = query.left_joins(:document_versions)
                            .group(Document.arel_table[:id])

        case rule.operator
        when EQUALS     then joined_query.having(version_count.eq(count_value))
        when NOT_EQUALS then joined_query.having(version_count.not_eq(count_value))
        when GREATER_THAN then joined_query.having(version_count.gt(count_value))
        when LESS_THAN    then joined_query.having(version_count.lt(count_value))
        else
          Rails.logger.warn "Unsupported version count operator '#{rule.operator}' for rule #{rule.id}"
          query
        end
      end

      private

      def parse_count_value
        Integer(rule.value)
      rescue ArgumentError, TypeError
        Rails.logger.error "Invalid number format for version count rule #{rule.id}: #{rule.value}"
        nil
      end
    end
  end
end
