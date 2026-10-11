# frozen_string_literal: true

# The ticket's tags, by name (Taggable writes the taggings at once for a
# persisted record). A name nobody has made yet may be added: the write
# creates the tag in the ticket's organisation. Removing stays limited to the
# tags the reader is offered.
#
# Entry point: apply
module Tickets
  module Changes
    class AddRemoveTags < AddRemoveBase
      def add
        normalized(super)
      end

      def remove
        normalized(Array(entry['remove'])) - add
      end

      def validate!
        raise Invalid.with(:nothing_to_change, key) if add.empty? && remove.empty?

        allowed = field.options.map { |option| option[:value].to_s }
        raise Invalid.with(:tag_name_invalid, key) if (add - allowed).any? { |name| !Tag.acceptable_new_name?(name) }
        raise Invalid.with(:value_not_allowed, key) if (remove - allowed).any?

        self
      end

      private

      def normalized(names)
        names.map { |name| Tag.normalize_name(name) }.reject(&:blank?).uniq
      end

      def current(ticket)
        ticket.tag_list.map(&:to_s)
      end

      def write(ticket, values, _before)
        ticket.tag_list = values
        ticket.tags.reset
      end
    end
  end
end
