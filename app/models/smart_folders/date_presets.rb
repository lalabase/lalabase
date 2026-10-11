# frozen_string_literal: true

# app/models/smart_folders/date_presets.rb
# The ONE table of the relative date presets on "created_at" and "updated_at": the quick-filter
# of the filter bar (AdHocFilterHelper), the query behind it (AdHocFilterService), the operators
# of the expert filter (SmartFolderRule.field_config), the query behind those
# (SmartFolders::Filters::DateFilter), and the two services that turn a bar condition into a
# folder rule and back (AdHocToSmartFolderService, SmartFolderDissolver).
# Plan: doc/filter_datumsvorgaben_rundlauf_plan.md.
#
# The preset key IS the rule operator. It is persisted verbatim in smart_folder_rules.operator
# and interpolated into i18n keys ("smart_folders.operators.#{key}"), exactly like the deadline
# presets in Ticket::DUE_DATE_PRESET_KEYS. A rule "created_at this_week" never goes stale: the
# range is computed when the rule runs, never when it is saved.
#
# Ranges are inclusive and start at the beginning of a day, so the bar's list and a folder's
# list answer alike, to the hour.
module SmartFolders
  module DatePresets
    RANGES = {
      'today' => -> { Time.current.beginning_of_day..Time.current.end_of_day },
      'yesterday' => -> { 1.day.ago.beginning_of_day..1.day.ago.end_of_day },
      'last_7_days' => -> { 7.days.ago.beginning_of_day..Time.current.end_of_day },
      'last_30_days' => -> { 30.days.ago.beginning_of_day..Time.current.end_of_day },
      'this_week' => -> { Time.current.beginning_of_week..Time.current.end_of_day },
      'this_month' => -> { Time.current.beginning_of_month..Time.current.end_of_day }
    }.freeze

    # In the order the bar lists them.
    KEYS = RANGES.keys.freeze

    def self.valid?(key)
      RANGES.key?(key.to_s)
    end

    # @return [Range<Time>, nil] the range as of now, nil for an unknown key
    def self.range(key)
      RANGES[key.to_s]&.call
    end
  end
end
