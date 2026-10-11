# frozen_string_literal: true

# A date field set to a day, or cleared on every selected ticket.
#
# Entry point: apply
module Tickets
  module Changes
    class SetDate < Base
      def clear?
        ActiveModel::Type::Boolean.new.cast(entry['clear']) == true
      end

      def value
        return nil if clear?

        entry['value'].to_s
      end

      def validate!
        return self if clear?
        raise Invalid.with(:date_invalid, key) unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value)

        self
      rescue Date::Error
        raise Invalid.with(:date_invalid, key)
      end

      def apply(ticket)
        before = ticket.custom_attributes[key]
        write_attribute(ticket, value)
        before
      end

      def restore(ticket, before)
        write_attribute(ticket, before.presence)
      end

      def still_applied?(ticket)
        ticket.custom_attributes[key].to_s == value.to_s
      end

      def to_h
        super.merge('value' => value, 'clear' => clear?)
      end

      private

      def describe_key
        clear? ? 'cleared' : 'set'
      end

      def describe_args
        { label: label, value: clear? ? nil : I18n.l(Date.iso8601(value)) }
      end
    end
  end
end
