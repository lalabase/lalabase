# frozen_string_literal: true

module SmartFolders
  module Filters
    class HasTimeSessionsFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, item_type)
        return query unless item_type == 'Ticket'

        has_sessions = should_have_sessions?

        case rule.operator
        when IS
          has_sessions ? with_time_sessions(query) : without_time_sessions(query)
        when IS_NOT
          has_sessions ? without_time_sessions(query) : with_time_sessions(query)
        else
          Rails.logger.warn "Unsupported operator '#{rule.operator}' for HasTimeSessionsFilter"
          query
        end
      end

      private

      def should_have_sessions?
        truthy_value?(rule.value)
      end

      def time_sessions_exist_condition
        ts = TimeSession.arel_table
        tickets = Ticket.arel_table

        ts.project(1)
          .where(ts[:ticket_id].eq(tickets[:id]))
          .where(ts[:deleted_at].eq(nil))
          .exists
      end

      def with_time_sessions(query)
        query.where(time_sessions_exist_condition)
      end

      def without_time_sessions(query)
        query.where(time_sessions_exist_condition.not)
      end
    end
  end
end
