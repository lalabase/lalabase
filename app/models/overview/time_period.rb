# frozen_string_literal: true

module Overview
  # Canonical selectable reporting periods for the personal overview widgets
  # (my_week_stats / my_week_chart) and their drill-down into the time-sessions
  # index. ONE source of truth so the widget figure and the drill-down sum always
  # use the exact same inclusive [start_at, end_at] window.
  module TimePeriod
    KEYS = %w[this_week this_month this_quarter last_10_days].freeze
    DEFAULT = 'this_week'
    LAST_N_DAYS = 10

    # Resolved window for one period. start_at/end_at are inclusive Time bounds
    # (beginning_of_day .. end_of_day) in the app zone; subtitle is localized.
    Resolved = Data.define(:key, :start_at, :end_at, :title_key, :subtitle)

    # Map any input to a known key; unknown/blank -> DEFAULT (whitelist hardening
    # for params coming off the wire).
    def self.normalize(key)
      KEYS.include?(key.to_s) ? key.to_s : DEFAULT
    end

    def self.title_key(key)
      "dashboard.briefing.period.title.#{normalize(key)}"
    end

    def self.range_for(key, now: Time.current)
      key = normalize(key)

      case key
      when 'this_week'
        start_at = now.beginning_of_week
        end_at   = now.end_of_week
        subtitle = I18n.t('dashboard.briefing.period.week_number', n: now.to_date.cweek)
      when 'this_month'
        start_at = now.beginning_of_month
        end_at   = now.end_of_month
        subtitle = I18n.l(now.to_date, format: '%B %Y')
      when 'this_quarter'
        start_at = now.beginning_of_quarter
        end_at   = now.end_of_quarter
        quarter  = ((now.to_date.month - 1) / 3) + 1
        subtitle = I18n.t('dashboard.briefing.period.quarter', q: quarter, year: now.year)
      when 'last_10_days'
        start_at = now - (LAST_N_DAYS - 1).days
        end_at   = now
        subtitle = "#{I18n.l(start_at.to_date, format: '%d.%m.')}–#{I18n.l(end_at.to_date, format: '%d.%m.')}"
      end

      Resolved.new(
        key: key,
        start_at: start_at.beginning_of_day,
        end_at: end_at.end_of_day,
        title_key: title_key(key),
        subtitle: subtitle
      )
    end
  end
end
