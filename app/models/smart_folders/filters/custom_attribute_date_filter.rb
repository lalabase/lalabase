# frozen_string_literal: true

module SmartFolders
  module Filters
    # Date-aware filter for custom DATE attributes stored as ISO strings in custom_attributes (jsonb).
    # Used instead of the numeric/text CustomAttributeFilter for date/datetime fields so the date
    # operators actually work: before/after/between compare lexicographically on the ISO string
    # (ISO YYYY-MM-DD sorts chronologically — no ::date cast, never throws on legacy garbage).
    #
    # Plus deadline-semantic RELATIVE operators that need no value (saveable as a smart folder, unlike
    # an absolute "before 2026-06-30" that goes stale tomorrow): overdue / due_today / due_this_week /
    # due_next_7_days. `overdue` reuses Ticket.overdue (past due AND not in a closed/completed status,
    # per the project's System Functions) so "overdue" means the same here as in the badge/chip/count.
    class CustomAttributeDateFilter < BaseFilter
      include SmartFolders::Operators

      # Reuse the one ISO date-only shape (see TicketAttributeDefinition) — keeps the storage format
      # and the filter's parse rule from drifting apart.
      ISO_DATE = TicketAttributeDefinition::ISO_DATE_FORMAT

      def apply(query, item_type)
        return query unless item_type == 'Ticket'

        attr = extract_attribute_name
        return query unless attr

        apply_operator(query, attr)
      end

      private

      def apply_operator(query, attr)
        table = query.table_name
        # Relative presets (overdue / due today / this week / next 7 days) share ONE implementation
        # with the FilterBar quick-filter via Ticket.matching_due_preset — see Ticket::DUE_DATE_PRESET_KEYS.
        return query.matching_due_preset(rule.operator) if Ticket::DUE_DATE_PRESET_KEYS.include?(rule.operator)

        case rule.operator
        when EQUALS          then present(query, attr).where("#{table}.custom_attributes->>? = ?", attr, iso(rule.value))
        when NOT_EQUALS      then query.where("#{table}.custom_attributes->>? IS DISTINCT FROM ?", attr, iso(rule.value))
        when BEFORE          then present(query, attr).where("#{table}.custom_attributes->>? < ?", attr, iso(rule.value))
        when AFTER           then present(query, attr).where("#{table}.custom_attributes->>? > ?", attr, iso(rule.value))
        when BETWEEN         then apply_between(query, attr)
        when IS_EMPTY, IS_BLANK         then presence(query, attr, empty: true)
        when IS_NOT_EMPTY, IS_NOT_BLANK then presence(query, attr, empty: false)
        else
          Rails.logger.warn "CustomAttributeDateFilter: unknown operator '#{rule.operator}' for attribute '#{attr}'"
          query
        end
      end

      def extract_attribute_name
        return nil unless rule.field&.start_with?('custom_')

        rule.field.delete_prefix('custom_')
      end

      # Parse a user-entered date (ISO / locale formats) into an ISO string, or nil on failure.
      def iso(value)
        str = value.to_s.strip
        return str if str.match?(ISO_DATE) && date_ok?(str)

        (Date.parse(str).iso8601 if str.present?)
      rescue ArgumentError, TypeError
        nil
      end

      def date_ok?(str)
        Date.iso8601(str)
        true
      rescue ArgumentError
        false
      end

      def present(query, attr)
        query.where("#{query.table_name}.custom_attributes->>? <> ''", attr)
      end

      def presence(query, attr, empty:)
        table = query.table_name
        if empty
          query.where("#{table}.custom_attributes->? IS NULL OR #{table}.custom_attributes->>? = ''", attr, attr)
        else
          query.where("#{table}.custom_attributes->? IS NOT NULL AND #{table}.custom_attributes->>? <> ''", attr, attr)
        end
      end

      def apply_between(query, attr)
        bounds = rule.value.to_s.split(',').filter_map { |part| iso(part) }
        return query if bounds.empty?

        low, high = bounds.sort
        high ||= low
        present(query, attr)
          .where("#{query.table_name}.custom_attributes->>? BETWEEN ? AND ?", attr, low, high)
      end
    end
  end
end
