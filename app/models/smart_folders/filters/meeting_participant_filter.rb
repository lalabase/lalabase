# frozen_string_literal: true

module SmartFolders
  module Filters
    class MeetingParticipantFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, _item_type)
        operator = case rule.operator
                   when NOT_EQUALS, NOT_HAS then 'not'
                   when HAS_ALL_OF then 'and'
                   else 'or'
                   end
        Meetings::ParticipantFilter.call(query, Meetings::ParticipantFilter.rule_values(rule.value), operator: operator)
      end
    end
  end
end
