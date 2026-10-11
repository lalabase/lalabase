# frozen_string_literal: true

# One change of one field, applied to one ticket at a time. Subclasses fill
# in validate!, apply and restore; describe is the one sentence the result
# line, the feed and the notification share.
#
# Entry point: apply
module Tickets
  module Changes
    class Base
      attr_reader :field, :entry

      def initialize(field:, entry:)
        @field = field
        @entry = entry
      end

      delegate :key, to: :field

      delegate :kind, to: :field

      def validate!
        raise NotImplementedError
      end

      # Writes the change into the ticket and returns what was there before.
      def apply(ticket)
        raise NotImplementedError
      end

      # Puts what was there before back.
      def restore(ticket, before)
        raise NotImplementedError
      end

      # Whether the ticket still carries what this change wrote: an undo
      # touches only those.
      def still_applied?(ticket)
        raise NotImplementedError
      end

      # The change as the run record keeps it.
      def to_h
        { 'field' => key, 'kind' => kind }
      end

      DESCRIBE_SCOPE = 'views.organisations.tickets.bulk.describe'

      def describe
        I18n.t("#{DESCRIBE_SCOPE}.#{describe_key}", **describe_args)
      end

      private

      def describe_key
        raise NotImplementedError
      end

      def describe_args
        {}
      end

      def label
        field.label
      end

      def option_label(value)
        field.options.find { |option| option[:value].to_s == value.to_s }&.dig(:label) || value.to_s
      end

      # The custom attribute writes share one path: the definition was checked
      # once for the run, the neighbours' legacy values must not block a
      # ticket (the board drag's old rule, F2 of doc/tickets_seam_umbau_plan.md).
      def write_attribute(ticket, value)
        attributes = ticket.custom_attributes.dup
        if value.nil?
          attributes.delete(key)
        else
          attributes[key] = value
        end
        ticket.skip_custom_attribute_validation = true
        ticket.custom_attributes = attributes
        ticket.save!
      end
    end
  end
end
