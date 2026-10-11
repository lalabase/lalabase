# frozen_string_literal: true

# The shared "period chrome" atop both personal week widgets (my_week_stats /
# my_week_chart): the section header (title + period subtitle) and the period
# switcher tabs. Extracted into ONE component because both widgets render an
# identical header + tab row — only the body below (figures vs chart) differs, so
# without this the header markup would be copy-pasted into both templates.
#
# Each tab is a Turbo-frame link to the overview widget refresh endpoint; clicking
# swaps only this widget's frame in place and persists the choice for the viewer.
class Overview::PeriodHeaderComponent < ViewComponent::Base
  def initialize(organisation:, widget_key:, period:, title_key:, subtitle:, frame_id:)
    @organisation = organisation
    @widget_key = widget_key
    @period = Overview::TimePeriod.normalize(period)
    @title_key = title_key
    @subtitle = subtitle
    @frame_id = frame_id
  end

  private

  attr_reader :organisation, :widget_key, :period, :title_key, :subtitle, :frame_id

  # One tab per selectable period; the active one is the current selection.
  def tabs
    Overview::TimePeriod::KEYS.map do |key|
      {
        key: key,
        label: I18n.t("dashboard.briefing.period.tab.#{key}"),
        active: key == period,
        url: helpers.organisation_overview_widget_path(organisation, widget_key, period: key)
      }
    end
  end

  def tab_classes(active)
    base = 'px-2 py-0.5 rounded-full text-xs font-mono transition-colors'
    if active
      "#{base} border border-ink bg-cream-200 text-cream-900 font-semibold"
    else
      "#{base} border border-cream-300 bg-cream-50 text-cream-600 hover:bg-cream-100 hover:border-cream-400"
    end
  end
end
