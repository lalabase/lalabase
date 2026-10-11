# frozen_string_literal: true

# The shape the multi-valued kinds share: values added on every selected
# ticket and values removed from every one, in one change, because it is one
# field (29a §5). Subclasses say how the ticket's current values are read and
# written.
#
# Entry point: apply
module Tickets
  module Changes
    class AddRemoveBase < Base
      def add
        Array(entry['add']).map(&:to_s).reject(&:blank?).uniq
      end

      def remove
        Array(entry['remove']).map(&:to_s).reject(&:blank?).uniq - add
      end

      # What may be added is what the field offers; what may be removed may be
      # more (BulkFields::Field#removable): a value that once was offered.
      def validate!
        raise Invalid.with(:nothing_to_change, key) if add.empty? && remove.empty?

        raise Invalid.with(:value_not_allowed, key) if (add - values_of(field.options)).any?

        outside = remove - values_of(field.options)
        raise Invalid.with(:value_not_allowed, key) if outside.any? && (outside - values_of(field.removable_options)).any?

        self
      end

      def apply(ticket)
        before = current(ticket)
        write(ticket, (before | add) - remove, before)
        before
      end

      # Puts the previous values back, minus those that may not come back
      # (#restorable): an undo leaves such a person off and restores the rest,
      # rather than failing the whole ticket.
      def restore(ticket, before)
        write(ticket, restorable(ticket, Array(before).map(&:to_s)), current(ticket))
      end

      def still_applied?(ticket)
        now = current(ticket)
        (add - now).empty? && (remove & now).empty?
      end

      def to_h
        super.merge('add' => add, 'remove' => remove)
      end

      private

      # Which of the previous values may be written back. Every one, unless a
      # subclass knows better.
      def restorable(_ticket, values)
        values
      end

      def values_of(options)
        Array(options).map { |option| option[:value].to_s }
      end

      # A removed value may stand outside the offered options (a deactivated
      # person); the result line still names it.
      def option_label(value)
        offered = field.options.find { |option| option[:value].to_s == value.to_s }
        return offered[:label] if offered

        field.removable_options.find { |option| option[:value].to_s == value.to_s }&.dig(:label) || value.to_s
      end

      def current(ticket)
        raise NotImplementedError
      end

      def write(ticket, values, before)
        raise NotImplementedError
      end

      def describe_key
        'add_remove'
      end

      def describe_args
        parts = add.map { |value| "+#{option_label(value)}" } + remove.map { |value| "−#{option_label(value)}" }
        { label: label, values: parts.join(' ') }
      end
    end
  end
end
