# frozen_string_literal: true

# app/models/smart_folders/filters/time_session_filter.rb
module SmartFolders
  module Filters
    # Filter for ticket-based time session aggregations (duration, count, billing status).
    class TimeSessionFilter < BaseFilter
      include SmartFolders::Operators
      include TimeSessionJoinable

      DURATION_AGGREGATE = 'SUM(time_sessions.duration)'
      COUNT_AGGREGATE = 'COUNT(time_sessions.id)'

      def apply(query, item_type)
        return query unless item_type == 'Ticket'

        case rule.field
        when 'time_session_duration'
          apply_aggregate_filter(query, DURATION_AGGREGATE)
        when 'time_session_count'
          apply_aggregate_filter(query, COUNT_AGGREGATE)
        when 'time_session_billed'
          apply_billed_filter(query)
        else
          Rails.logger.warn "Unsupported field '#{rule.field}' for TimeSessionFilter"
          query
        end
      end

      private

      def apply_aggregate_filter(query, aggregate)
        joined_query = add_time_sessions_join(query)

        case rule.operator
        when EQUALS
          joined_query.group('tickets.id').having("#{aggregate} = ?", parse_integer_value)
        when NOT_EQUALS
          joined_query.group('tickets.id')
                      .having("#{aggregate} != ? OR #{aggregate} IS NULL", parse_integer_value)
        when GREATER_THAN
          joined_query.group('tickets.id').having("#{aggregate} > ?", parse_integer_value)
        when LESS_THAN
          joined_query.group('tickets.id').having("#{aggregate} < ?", parse_integer_value)
        when BETWEEN
          min_val, max_val = parse_number_range(rule.value).map(&:to_i)
          joined_query.group('tickets.id').having("#{aggregate} BETWEEN ? AND ?", min_val, max_val)
        else
          Rails.logger.warn "Unsupported operator '#{rule.operator}' for #{rule.field}"
          query
        end
      rescue ArgumentError, TypeError => e
        Rails.logger.error "Invalid number format for rule #{rule.id}: '#{rule.value}'. Error: #{e.message}"
        query.none
      end

      def parse_integer_value
        parse_number(rule.value).to_i
      end

      def apply_billed_filter(query)
        unless [IS, IS_NOT].include?(rule.operator)
          Rails.logger.warn "Unsupported operator '#{rule.operator}' for time_session_billed"
          return query
        end

        joined_query = add_time_sessions_join(query)
        wants_billed = truthy_value?(rule.value) == (rule.operator == IS)

        if wants_billed
          joined_query.where.not(time_sessions: { billed_at: nil }).distinct
        else
          joined_query.group('tickets.id')
                      .having('COUNT(CASE WHEN time_sessions.billed_at IS NOT NULL THEN 1 END) = 0')
        end
      end
    end
  end
end
