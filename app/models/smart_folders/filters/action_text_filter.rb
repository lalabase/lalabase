# frozen_string_literal: true

module SmartFolders
  module Filters
    # Filter for ActionText content (rich text).
    # Supports two paths:
    # 1. Denormalized plain_text_version column (e.g. Note)
    # 2. JOIN onto the action_text_rich_texts table (e.g. Ticket)
    class ActionTextFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, item_type)
        if item_type == 'Meeting'
          # Both text sources belong to a meeting's content, including AI summaries.
          columns = %i[plain_text_version generated_summary].map { |key| query.arel_table[key] }
          positive_operator = { NOT_CONTAINS => CONTAINS, NOT_EQUALS => EQUALS }.fetch(rule.operator, rule.operator)
          value = rule.value.to_s
          predicates = columns.map do |column|
            positive_operator == EQUALS ? lower(column).eq(quoted(value.downcase)) : column.matches("%#{sanitized(value)}%")
          end
          matches = predicates.reduce(:or)
          if [NOT_CONTAINS, NOT_EQUALS].include?(rule.operator)
            # Excluding matching ids also retains meetings with a NULL text source.
            return query.where.not(id: query.where(matches).select(:id))
          end

          return query.where(matches)
        end

        rich_text_field = get_field_name(item_type)

        if plain_text_version_path?(query, rich_text_field)
          apply_to_plain_text_version(query)
        else
          apply_to_action_text(query, rich_text_field)
        end
      end

      private

      def plain_text_version_path?(query, rich_text_field)
        query.model.column_names.include?('plain_text_version') && rich_text_field.to_s == 'content'
      end

      def apply_to_plain_text_version(query)
        column = query.model.arel_table[:plain_text_version]
        apply_operator(query, column)
      end

      def apply_to_action_text(query, rich_text_field)
        joined_query = ensure_action_text_join(query, rich_text_field)
        column = ActionText::RichText.arel_table[:body]
        apply_operator(joined_query, column)
      end

      def ensure_action_text_join(query, rich_text_field)
        return query if already_joined?(query)

        connection = ActiveRecord::Base.connection
        table_name = query.model.table_name
        record_type = connection.quote(query.model.name)
        field_name = connection.quote(rich_text_field.to_s)

        query.joins(
          'LEFT JOIN action_text_rich_texts ON ' \
          "action_text_rich_texts.record_id = #{table_name}.id AND " \
          "action_text_rich_texts.record_type = #{record_type} AND " \
          "action_text_rich_texts.name = #{field_name}"
        )
      end

      def already_joined?(query)
        query.joins_values.any? do |join|
          join.is_a?(String) && join.include?('action_text_rich_texts')
        end
      end

      def apply_operator(query, column)
        text_value = rule.value.to_s

        case rule.operator
        when CONTAINS
          query.where(column.matches("%#{sanitized(text_value)}%"))
        when NOT_CONTAINS
          query.where(
            column.does_not_match("%#{sanitized(text_value)}%")
              .or(column.eq(nil))
              .or(column.eq(''))
          )
        when EQUALS
          query.where(lower(column).eq(quoted(text_value.downcase)))
        when NOT_EQUALS
          query.where(
            lower(column).not_eq(quoted(text_value.downcase))
              .or(column.eq(nil))
              .or(column.eq(''))
          )
        when STARTS_WITH
          query.where(column.matches("#{sanitized(text_value)}%"))
        when ENDS_WITH
          query.where(column.matches("%#{sanitized(text_value)}"))
        else
          Rails.logger.warn "Unsupported text operator '#{rule.operator}' for rule #{rule.id}"
          query
        end
      end

      def sanitized(value)
        ActiveRecord::Base.sanitize_sql_like(value)
      end

      def lower(column)
        Arel::Nodes::NamedFunction.new('LOWER', [column])
      end

      def quoted(value)
        Arel::Nodes.build_quoted(value)
      end
    end
  end
end
