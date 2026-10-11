# frozen_string_literal: true

# Overview widget: the viewer's own tracked/unbilled hours for the selected period
# (this week / month / quarter / last 10 days). Thin wrapper around the shared
# Dashboard::DailyBriefing#period_hours; period switching + drill-down live in
# Overview::PeriodWidget.
#
# should_render? is permission-only and DOES gate (unlike the always-on feed/table):
# hours are a time-tracking concern, so the widget is shown only to viewers with
# time_sessions:read in AT LEAST ONE project (Current.area_access_anywhere?, the org
# "any project" primitive). No "no data" gate — zero hours render the 0-state in the card.
class Overview::WeekStatsComponent < ViewComponent::Base
  include Overview::PeriodWidget # period/frame/drill-down + Turbo::FramesHelper

  WIDGET_KEY = 'my_week_stats'

  private

  # Share of tracked hours still unbilled, or nil when nothing is tracked (avoids 0/0).
  def unbilled_percent
    return nil unless data[:tracked].positive?

    ((data[:unbilled] / data[:tracked]) * 100).round
  end
end
