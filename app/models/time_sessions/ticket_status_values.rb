# frozen_string_literal: true

module TimeSessions
  # The status values of ONE project, for the time list's ticket filter (step
  # 3b of doc/zeiten_weitere_filter_plan.md, E3). The three phases
  # (TimeSessions::TicketPhase) mean the same in every project; these are the
  # project's own words ("Fertig", "In Review") and are offered only while that
  # project is chosen.
  #
  # Entry point: for(project), then find.
  #
  # Read from the project's active status field, in its configured order, each
  # value in the reader's language (TicketAttributeDefinition#display_value).
  # Never a hard-coded status string (docs/architektur/tickets_lesepfad.md).
  module TicketStatusValues
    Choice = Data.define(:value, :label)

    class << self
      def for(project)
        definition = TicketAttributeDefinition.active.find_by(project: project, name: 'status', field_type: 'select')
        return [] unless definition

        definition.ordered_value_keys.map do |value|
          Choice.new(value: value.to_s, label: definition.display_value(value).to_s)
        end
      end

      # The choice a typed value names. Compared the way the filter matches,
      # exactly (TimeSessionFilterService#apply_ticket_status_filter): a page
      # that named no value over a list the query had narrowed by it, or the
      # other way round, would disagree with itself (the lesson of
      # ListFilters.normalize_id).
      def find(choices, raw)
        return unless raw.is_a?(String)

        choices.find { |choice| choice.value == raw }
      end
    end
  end
end
