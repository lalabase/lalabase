# frozen_string_literal: true

# A select field (status, priority, a custom select) set to one of its
# options, or cleared (the board's drop into the "unset" column sends
# clear; the panel offers no clear for a select).
#
# Entry point: apply
module Tickets
  module Changes
    class SetSelect < Base
      def clear?
        ActiveModel::Type::Boolean.new.cast(entry['clear']) == true
      end

      def value
        return nil if clear?

        entry['value'].to_s
      end

      def validate!
        return self if clear?
        raise Invalid.with(:value_not_allowed, key) unless field.options.any? { |option| option[:value].to_s == value }

        self
      end

      # A clear of a field the ticket must carry is refused HERE, in the write
      # path, whatever the board shows: the board's missing "Nicht zugeordnet"
      # column is a courtesy (KanbanBoardPresenter), this is the rule. The
      # definition answers per ticket, so a conditional requirement follows the
      # ticket (S8 of doc/kanban_ticket_als_bahn_plan.md).
      def apply(ticket)
        raise NotApplicable.with(:required) if clear? && field.definition&.required_for?(ticket)

        before = ticket.custom_attributes[key]
        write_attribute(ticket, value)
        before
      end

      def restore(ticket, before)
        write_attribute(ticket, before)
      end

      def still_applied?(ticket)
        ticket.custom_attributes[key].to_s == value.to_s
      end

      # The run record keeps the clear only when there is one; a set select
      # reads as it did before the board could clear.
      def to_h
        record = super.merge('value' => value)
        record['clear'] = true if clear?
        record
      end

      private

      def describe_key
        clear? ? 'cleared' : 'set'
      end

      def describe_args
        { label: label, value: clear? ? nil : option_label(value) }
      end
    end
  end
end
