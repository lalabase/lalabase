# frozen_string_literal: true

module TimeSessions
  # The selectable periods of the time area: the eight presets the list filter
  # offers and the status table above it now offers too, in ONE display order,
  # with ONE resolution to date bounds and ONE set of labels.
  #
  # Entry point: normalize_for_list / normalize_for_table, then bounds_for.
  #
  # Why an owner: before S5 the eight keys were a literal array inside
  # _filter_pills, their labels were eight `t(...)` calls beside it, and the
  # key -> date mapping was a `case` in the controller. The table needs exactly
  # the same vocabulary, and a second copy of a mapping is how a cell comes to
  # promise a different window than the list it opens. Same argument as the
  # billing state names in S1.
  #
  # The two surfaces differ in exactly two ways, and both are declared here:
  # the list defaults to the current month and additionally offers `custom`
  # (hand-typed bounds), the table defaults to all time and does not. A period
  # on a single table column would make the row untrue, so the table's period
  # governs every column at once (D3 of the filter-line plan).
  module ListPeriod
    # Display order, left to right: the short windows first, then the long ones,
    # "alles" last. _filter_pills renders the segments in this order and the
    # table's dropdown lists them in it.
    KEYS = %w[this_week this_month this_quarter last_10_days 30_days 90_days year all].freeze

    # Hand-typed bounds. Not a period in the sense above (its window comes from
    # two date fields, not from the key), which is why it is not in KEYS and why
    # the table does not offer it.
    CUSTOM = 'custom'
    LIST_KEYS = (KEYS + [CUSTOM]).freeze

    LIST_DEFAULT = 'this_month'
    TABLE_DEFAULT = 'all'

    # The keys whose window belongs to Overview::TimePeriod, the period model of
    # the dashboard widgets. Declared as an intersection rather than written
    # out, so adding a key on either side cannot silently leave a second
    # definition of the same window behind. A widget drill-down lands in this
    # list, and its figure has to be reproducible there to the minute.
    SHARED_WITH_OVERVIEW = (KEYS & Overview::TimePeriod::KEYS).freeze

    LABEL_KEY_PREFIX = 'views.organisations.time_sessions.index.filter_range_'

    class << self
      # Whitelist hardening for a value off the wire. Anything unknown becomes
      # the surface's default: an unknown key used to travel on untouched, which
      # lit no segment, applied no window and left the empty state naming raw
      # dates instead of a period.
      def normalize_for_list(key)
        LIST_KEYS.include?(key.to_s) ? key.to_s : LIST_DEFAULT
      end

      def normalize_for_table(key)
        KEYS.include?(key.to_s) ? key.to_s : TABLE_DEFAULT
      end

      # Inclusive [start_date, end_date] for a key. `all` and `custom` have no
      # window of their own and answer [nil, nil]: for `all` that IS the answer,
      # for `custom` the bounds come from the two date fields instead.
      def bounds_for(key, today: Date.current)
        key = key.to_s
        return overview_bounds(key, today) if SHARED_WITH_OVERVIEW.include?(key)

        case key
        when '30_days' then [today - 30.days, today]
        when '90_days' then [today - 90.days, today]
        when 'year'    then [today.beginning_of_year, today.end_of_year]
        else [nil, nil]
        end
      end

      def label_key(key)
        "#{LABEL_KEY_PREFIX}#{key}"
      end

      def label(key)
        I18n.t(label_key(key))
      end

      # [key, label] for every preset, ready to iterate. The table's dropdown and
      # the list's segments read the same pairs in the same order.
      def options
        KEYS.map { |key| [key, label(key)] }
      end

      private

      # Delegated, not recomputed: the widgets' figure and the drill-down sum
      # have to come from the exact same window (Overview::TimePeriod's own
      # reason for existing).
      #
      # `today` is passed ON, not dropped. Without it these four keys answered
      # from the wall clock while the other four honoured the argument, so the
      # same parameter meant something for half the vocabulary and nothing for
      # the other half -- a seam that lies, in the very class that exists to
      # stop a second definition of a window.
      def overview_bounds(key, today)
        period = Overview::TimePeriod.range_for(key, now: today.in_time_zone)
        [period.start_at.to_date, period.end_at.to_date]
      end
    end
  end
end
