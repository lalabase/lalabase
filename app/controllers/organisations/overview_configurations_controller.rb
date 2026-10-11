# frozen_string_literal: true

# Inline editor for the organisation overview (briefings#show). Org-scoped sibling of the project
# DashboardConfigurationsController: same shared editor orchestration (Dashboards::Configurable) +
# the same shared editor view (shared/dashboards/_editor), bound to the OVERVIEW surface via the
# editor_* hooks. What genuinely diverges and stays here: the two org save scopes (personal /
# org-default) — the overview is a single org-level surface, so there is no cross-project "_all"
# scope. See doc/overview_widgets_plan.md.
class Organisations::OverviewConfigurationsController < Organisations::BaseController
  include Dashboards::Configurable

  # Like briefings#show: the overview only renders data the viewer is already authorised for (each
  # widget self-gates), so there is no per-record policy. The org-default save scope is gated on
  # account_admin inside save_scope.
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  # Save destinations selected via the single `save_scope` radio in the edit form. `personal` writes
  # the user's own overview; `default` writes the shared org default (user_id NULL) and is admin-only.
  # Keep in sync with the radio values in overview_configurations/_save_scopes.html.erb.
  SAVE_SCOPES = %w[personal default].freeze

  def edit
    @configuration = OverviewConfiguration.for_user_organisation(current_user, @current_organisation)
    # Data deps (available widgets / admin flag / the shared briefing) live in load_edit_data so the
    # happy edit page and the 422 re-render (render_layout_error) can never show a different widget/
    # admin set — or a missing briefing — for the same form.
    load_edit_data
  end

  # The write itself (both scopes, transaction, override clearing) lives in
  # Actors::SaveOverviewLayout. A2: on failure the actor's resource is the rebuilt config
  # carrying the rejected layout, which must re-render INSIDE the turbo frame — a redirect
  # or re-raise here would leave Turbo without a frame ("Content missing", turbo#1005).
  def update
    layout = parse_layout_from_params
    return render_empty_layout_error(layout) if layout.blank?

    scope = save_scope
    result = Actors::SaveOverviewLayout.call(
      organisation: @current_organisation, current_user: current_user,
      layout: layout, scope: scope
    )

    if result.success?
      redirect_to organisation_root_path(@current_organisation), notice: saved_notice(scope)
    else
      render_layout_error(result.resource)
    end
  end

  def reset
    # Delete the user-specific config -> falls back to the org default (then the system default).
    config = OverviewConfiguration.find_by(user: current_user, organisation: @current_organisation)
    config&.destroy

    redirect_to organisation_root_path(@current_organisation),
                notice: t('overview.configuration.reset')
  end

  # Live WYSIWYG preview of one widget with its still-unsaved settings (shared, see
  # Dashboards::Configurable#render_widget_preview).
  def widget_preview
    load_edit_data
    render_widget_preview
  end

  private

  # --- Surface hooks for Dashboards::Configurable (overview binding) ---
  def editor_widget_registry
    Overview::WidgetRegistry::WIDGETS
  end

  # Component constructor context for the overview widgets: the org, the viewer, and the one shared
  # DailyBriefing the live previews reuse (so a preview doesn't re-run every aggregate query).
  def editor_base_params
    { organisation: @current_organisation, user: current_user, briefing: briefing }
  end

  def editor_configuration(layout)
    config = OverviewConfiguration.for_user_organisation(current_user, @current_organisation)
    config.layout = layout
    config
  end

  # Whitelisted save target. Non-admins can never reach the `default` scope: it writes the shared org
  # default (affects every member), so it falls back to a personal save.
  def save_scope
    scope = params[:save_scope].presence_in(SAVE_SCOPES) || 'personal'
    return 'personal' if scope == 'default' && !current_user.account_admin_in?(@current_organisation)

    scope
  end

  def saved_notice(scope)
    scope == 'default' ? t('overview.configuration.saved_as_default') : t('overview.configuration.saved')
  end

  def load_edit_data
    # The picker offers only widgets the viewer may see somewhere: overview widgets aggregate across
    # ALL the viewer's projects, so availability is an "access in ANY project" question (the org
    # primitive), not the single-project policy the project dashboard uses.
    @available_widgets = Dashboards::LayoutEngine.available_widgets_in(registry: Overview::WidgetRegistry::WIDGETS) do |area, action|
      Current.area_access_anywhere?(current_user, @current_organisation, area, action)
    end
    @is_admin = current_user.account_admin_in?(@current_organisation)
    # The edit view's base_params reuses this one DailyBriefing for the live widget previews — set
    # here (not just in #edit) so the 422 re-render path has it too (render_layout_error → load_edit_data).
    # The projects_table "selected projects" picker uses the canonical selectable_projects helper
    # (Organisations::ProjectScoping) directly in the view — no ivar here (it owns @selectable_projects).
    @briefing = briefing
  end

  # One shared DailyBriefing for the live widget previews (memoised so every preview in a request
  # reuses the same aggregates), mirroring briefings#show.
  def briefing
    @briefing ||= Dashboard::DailyBriefing.new(user: current_user, organisation: @current_organisation)
  end
end
