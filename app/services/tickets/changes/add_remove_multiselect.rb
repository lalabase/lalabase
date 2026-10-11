# frozen_string_literal: true

# A multiselect definition: an array in the ticket's custom attributes.
#
# Entry point: apply
module Tickets
  module Changes
    class AddRemoveMultiselect < AddRemoveBase
      private

      def current(ticket)
        Array(ticket.custom_attributes[key]).map(&:to_s)
      end

      def write(ticket, values, _before)
        write_attribute(ticket, values)
      end
    end
  end
end
