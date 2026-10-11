# frozen_string_literal: true

module SmartFolders
  module Filters
    # The rule form of a waiting state (Tickets::WaitingStateFilter): IS and IS_NOT on a boolean
    # value, the same truth table as HasTimeSessionsFilter. WaitingFilter and BlockingFilter name
    # the state; the meaning is Tickets::Waiting's.
    class WaitingStateFilter < BaseFilter
      include SmartFolders::Operators

      # Whether `rule` asks for the tickets IN the state: "is true" and "is_not false" do, "is
      # false" and "is_not true" ask for the rest. Nil for any other operator. SmartFolderDissolver
      # reads a rule back into the bar's "ist" / "ist nicht" by the same table.
      def self.wants_state?(rule)
        return nil unless [IS, IS_NOT].include?(rule.operator)

        (rule.operator == IS) == TRUTHY_VALUES.include?(rule.value)
      end

      def apply(query, item_type)
        return query unless item_type == 'Ticket'

        present = self.class.wants_state?(rule)
        if present.nil?
          Rails.logger.warn "Unsupported operator '#{rule.operator}' for #{self.class.name}"
          return query
        end

        Tickets::WaitingStateFilter.call(scope: query, state: self.class::STATE, present: present)
      end
    end
  end
end
