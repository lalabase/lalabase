# frozen_string_literal: true

# A yes/no field set on every selected ticket.
#
# Entry point: apply
module Tickets
  module Changes
    class SetCheckbox < Base
      def value
        ActiveModel::Type::Boolean.new.cast(entry['value'])
      end

      def validate!
        raise Invalid.with(:value_not_allowed, key) unless %w[true false].include?(entry['value'].to_s)

        self
      end

      def apply(ticket)
        before = ticket.custom_attributes[key]
        write_attribute(ticket, value)
        before
      end

      def restore(ticket, before)
        write_attribute(ticket, before)
      end

      def still_applied?(ticket)
        ActiveModel::Type::Boolean.new.cast(ticket.custom_attributes[key]) == value
      end

      def to_h
        super.merge('value' => value)
      end

      private

      def describe_key
        'set'
      end

      def describe_args
        { label: label, value: I18n.t("views.organisations.tickets.bulk.#{value ? 'yes' : 'no'}") }
      end
    end
  end
end
