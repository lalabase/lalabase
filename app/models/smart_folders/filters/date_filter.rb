# frozen_string_literal: true

module SmartFolders
  module Filters
    class DateFilter < BaseFilter
      include SmartFolders::Operators

      GERMAN_DATE_FORMAT = /^\d{1,2}\.\d{1,2}\.\d{4}$/
      US_DATE_FORMAT     = %r{^\d{1,2}/\d{1,2}/\d{4}$}
      ISO_DATE_FORMAT    = /^\d{4}-\d{2}-\d{2}$/

      def apply(query, item_type)
        column = safe_column_name(query, item_type)
        return query unless column

        apply_operator(query, arel_table(query), column)
      rescue StandardError => e
        Rails.logger.error "Error applying date filter for rule #{rule.id} (#{rule.operator} on #{column}): #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        query
      end

      private

      def apply_operator(query, arel, column)
        col = arel[column]

        case rule.operator
        when EQUALS      then apply_equals(query, col)
        when NOT_EQUALS  then apply_not_equals(query, col)
        when BEFORE      then apply_before(query, col)
        when AFTER       then apply_after(query, col)
        when BETWEEN     then apply_between(query, col)
        when *RELATIVE_DATE
          apply_within_days(query, col)
        when *SmartFolders::DatePresets::KEYS
          apply_preset(query, col)
        else
          Rails.logger.warn "Unsupported date operator '#{rule.operator}' for rule #{rule.id}. Skipping rule."
          query
        end
      end

      # A preset operator (today, this_week, ...) carries no value: the range is computed when
      # the rule runs, from the one table both filter surfaces read (SmartFolders::DatePresets),
      # so the bar's list and the folder's list answer alike, to the hour.
      def apply_preset(query, col)
        range = SmartFolders::DatePresets.range(rule.operator)
        query.where(col.gteq(range.begin).and(col.lteq(range.end)))
      end

      def apply_equals(query, col)
        date = parse_date(rule.value)
        return query if date.nil?

        day_start = date.beginning_of_day
        query.where(col.gteq(day_start).and(col.lt(day_start + 1.day)))
      end

      def apply_not_equals(query, col)
        date = parse_date(rule.value)
        return query if date.nil?

        day_start = date.beginning_of_day
        query.where(
          col.lt(day_start)
            .or(col.gteq(day_start + 1.day))
            .or(col.eq(nil))
        )
      end

      def apply_before(query, col)
        date = parse_date(rule.value)
        return query if date.nil?

        query.where(col.lt(date.beginning_of_day))
      end

      def apply_after(query, col)
        date = parse_date(rule.value)
        return query if date.nil?

        query.where(col.gteq(date.beginning_of_day + 1.day))
      end

      def apply_between(query, col)
        start_date, end_date = parse_date_range(rule.value)

        query.where(col.gteq(start_date.beginning_of_day)
                       .and(col.lt(end_date.beginning_of_day + 1.day)))
      rescue ArgumentError => e
        Rails.logger.warn "Invalid date range for rule #{rule.id}: #{e.message}. Skipping rule."
        query
      end

      def apply_within_days(query, col)
        days = rule.value.to_i
        if days <= 0
          Rails.logger.warn "Invalid days value '#{rule.value}' for rule #{rule.id}. Defaulting to 1."
          days = 1
        end

        query.where(col.gteq(days.days.ago))
      end

      # @param date_string [String]
      # @return [Date, nil]
      def parse_date(date_string)
        return nil if date_string.blank?

        date_str = date_string.to_s.strip

        case date_str
        when ISO_DATE_FORMAT    then Date.parse(date_str)
        when GERMAN_DATE_FORMAT then parse_german_date(date_str)
        when US_DATE_FORMAT     then parse_us_date(date_str)
        else Date.parse(date_str)
        end
      rescue ArgumentError
        nil
      end

      def parse_german_date(str)
        day, month, year = str.split('.')
        Date.new(year.to_i, month.to_i, day.to_i)
      end

      def parse_us_date(str)
        month, day, year = str.split('/')
        Date.new(year.to_i, month.to_i, day.to_i)
      end

      # @param range_string [String] e.g. "2023-01-10,2023-01-15"
      # @return [Array<Date>] [start_date, end_date]
      # @raise [ArgumentError] on invalid format
      def parse_date_range(range_string)
        return [Date.current, Date.current] if range_string.blank?

        parsed_dates = range_string.to_s.split(',').map { |d| parse_date(d.strip) }.compact

        case parsed_dates.length
        when 0
          raise ArgumentError, I18n.t('models.smart_folders.filters.date_filter.invalid_range', range: range_string)
        when 1
          [parsed_dates[0], parsed_dates[0]]
        else
          parsed_dates.first(2).sort
        end
      end
    end
  end
end
