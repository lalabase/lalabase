# frozen_string_literal: true

# Refreshes a SINGLE personal overview widget into its own Turbo frame when the
# viewer switches its reporting period. Keeps the dashboard fast: only the one
# widget re-renders, not the whole briefings#show layout.
#
# Authorization mirrors the widget itself (no Pundit record): the component's own
# should_render? gate (time_sessions:read in any project) decides; an unauthorised
# or unknown widget gets a 404/403, never another widget's data.
class Organisations::OverviewWidgetsController < Organisations::BaseController
  # Permission is enforced inline via the component gate (same as briefings#show).
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  # The only period-aware widgets. Anything else is not refreshable here.
  PERIOD_WIDGETS = {
    'my_week_stats' => Overview::WeekStatsComponent,
    'my_week_chart' => Overview::WeekChartComponent
  }.freeze

  def show
    component_class = PERIOD_WIDGETS[params[:key].to_s]
    return head(:not_found) if component_class.nil?

    period = Overview::TimePeriod.normalize(params[:period])

    briefing = Dashboard::DailyBriefing.new(user: current_user, organisation: @current_organisation)
    component = component_class.new(
      organisation: @current_organisation, user: current_user, briefing: briefing, period: period
    )

    # Same gate as the widget on the dashboard — a viewer without time access here
    # would not see the widget at all, so refreshing it is forbidden.
    return head(:forbidden) unless component.should_render?

    # Persist the choice so a full page reload keeps the selected period.
    current_user.preference_store.set_overview_widget_period(params[:key], period)

    # Just the widget's Turbo frame — no application layout (the frame is swapped
    # into the existing page).
    render component, layout: false
  end
end
