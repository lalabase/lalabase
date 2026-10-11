# frozen_string_literal: true

# Refreshes a SINGLE project-dashboard widget into its own Turbo frame — currently
# only the recent_tickets widget's live in-widget search. Keeps the dashboard fast:
# only that one widget re-renders, not the whole projects#show layout. Mirrors the
# org-scoped Organisations::OverviewWidgetsController.
#
# Authorization mirrors the widget itself (no Pundit record): the component's own
# should_render? gate (tickets:read in this project) decides; an unauthorised or
# unknown widget gets a 403/404, never another project's data.
class Organisations::DashboardWidgetsController < Organisations::BaseController
  include ProjectController

  # The component gate enforces permission inline (same as projects#show). Skip the
  # generic project-area check (its controller-name-derived area would be wrong here)
  # and Pundit's verify_* (no record is authorized in this lightweight frame endpoint).
  skip_before_action :authorize_project_access!
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  # The only refreshable widgets. Anything else is not refreshable here.
  WIDGETS = {
    'recent_tickets' => Dashboard::RecentTicketsComponent
  }.freeze

  def show
    component_class = WIDGETS[params[:key].to_s]
    return head(:not_found) if component_class.nil?

    component = component_class.new(
      project: @project,
      user: current_user,
      display: params[:display],
      period: params[:period],
      limit: params[:limit],
      search_query: params[:q],
      frame_only: true
    )

    # Same gate as the widget on the dashboard — a viewer without tickets:read here
    # would not see the widget at all, so refreshing it is forbidden.
    return head(:forbidden) unless component.should_render?

    # Just the widget's Turbo frame — no application layout (the frame is swapped
    # into the existing page).
    render component, layout: false
  end
end
