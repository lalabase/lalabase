# frozen_string_literal: true

# app/models/smart_folders/filters/time_session_joinable.rb
module SmartFolders
  module Filters
    # Shared join logic for filters that aggregate time_sessions on tickets.
    # Used by TimeSessionFilter and HasTimeSessionsFilter.
    module TimeSessionJoinable
      private

      def add_time_sessions_join(query)
        if query.joins_values.any? { |join| join.to_s.include?('time_sessions') }
          query
        else
          query.joins(
            'LEFT JOIN time_sessions ON time_sessions.ticket_id = tickets.id AND time_sessions.deleted_at IS NULL'
          )
        end
      end
    end
  end
end
