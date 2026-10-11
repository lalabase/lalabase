# frozen_string_literal: true

# The registry of what a bulk change can do to one ticket
# (doc/ticket_bulk_edit_plan.md, D13). One small class per kind, each with
# validate!, apply(ticket) returning the previous value, restore(ticket,
# before), and describe. The actor is the loop around them; the catalogue
# (Tickets::BulkFields) says which kind a field has, so the panel and the
# server can never disagree.
#
# Entry point: build
module Tickets
  module Changes
    # Refused before any ticket is touched. No initialize of its own: the
    # service convention wants keyword arguments, and an exception takes its
    # message positionally, so the code rides along after construction.
    class Invalid < StandardError
      attr_accessor :code

      def self.with(code, message = nil)
        error = new(message || code.to_s)
        error.code = code
        error
      end

      # The sentence the panel and the board show for it. One place, because
      # two actors build changes (ApplyTicketChanges, UndoTicketBulkRun).
      def translated
        I18n.t("views.organisations.tickets.bulk.errors.#{code}", max_tag_name: Tag::MAX_NAME_LENGTH, default: message)
      end
    end

    # A change that cannot be applied to THIS ticket (the run goes on, the
    # ticket is named in the results).
    class NotApplicable < StandardError
      attr_accessor :code

      def self.with(code)
        error = new(code.to_s)
        error.code = code
        error
      end
    end

    def self.build(params, catalogue:)
      entries = Array(params).map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h }
      raise Invalid.with(:no_changes) if entries.empty?

      fields = catalogue.index_by(&:key)
      changes = entries.map do |entry|
        entry = entry.transform_keys(&:to_s)
        field = fields[entry['field'].to_s] or raise Invalid.with(:unknown_field, entry['field'].to_s)
        klass_for(field).new(field: field, entry: entry)
      end
      raise Invalid.with(:field_twice) if changes.map(&:key).uniq.size != changes.size

      changes.each(&:validate!)
    end

    def self.klass_for(field)
      case field.kind
      when 'single' then SetSelect
      when 'date' then SetDate
      when 'boolean' then SetCheckbox
      when 'multi'
        case field.key
        when BulkFields::TAGS then AddRemoveTags
        when BulkFields::ASSIGNEES then AddRemoveAssignees
        when BulkFields::WATCHERS then AddRemoveWatchers
        else AddRemoveMultiselect
        end
      else raise Invalid.with(:unknown_kind, field.kind)
      end
    end
  end
end
