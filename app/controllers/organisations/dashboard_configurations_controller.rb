# frozen_string_literal: true

class Organisations::DashboardConfigurationsController < Organisations::BaseController
  include ProjectController
  include Dashboards::Configurable

  skip_before_action :authorize_project_access!

  # Save destinations selected via the single `save_scope` radio in the edit form.
  # Each value is a complete „who + where" target; the `default_*` scopes are admin-only.
  # Keep in sync with the radio values in edit.html.erb.
  SAVE_SCOPES = %w[personal_this personal_all default_this default_all].freeze

  def edit
    authorize @project, :show?

    @configuration = DashboardConfiguration.for_user_project(current_user, @project)
    @configuration.organisation = @current_organisation
    # The form's data deps (available widgets / smart folders / admin flag) live in load_edit_data
    # so the happy edit page and the 422 re-render (render_layout_error) can never show a different
    # widget/folder/admin set for the same form.
    load_edit_data
  end

  # The write itself (scope dispatch, transaction, override clearing) lives in
  # Actors::SaveDashboardLayout. A2: on failure the actor's resource is the rebuilt config
  # carrying the rejected layout, which must re-render INSIDE the turbo frame — a redirect
  # or re-raise here would leave Turbo without a frame ("Content missing", turbo#1005).
  def update
    authorize @project, :show?

    layout = parse_layout_from_params
    return render_empty_layout_error(layout) if layout.blank?

    scope = save_scope
    projects = policy_scope(Project)
    result = Actors::SaveDashboardLayout.call(
      project: @project, projects: projects, organisation: @current_organisation,
      current_user: current_user, layout: layout, scope: scope
    )

    if result.success?
      redirect_to organisation_project_path(@current_organisation, @project),
                  notice: saved_notice(scope, projects)
    else
      render_layout_error(result.resource)
    end
  end

  def reset
    authorize @project, :show?

    # Delete user-specific config -> falls back to the project default
    config = DashboardConfiguration.find_by(user: current_user, project: @project)
    config&.destroy

    redirect_to organisation_project_path(@current_organisation, @project),
                notice: t('dashboard.configuration.reset')
  end

  # Live WYSIWYG preview of one widget with its still-unsaved settings (shared, see
  # Dashboards::Configurable#render_widget_preview).
  def widget_preview
    authorize @project, :show?
    load_edit_data
    render_widget_preview
  end

  private

  # --- Surface hooks for Dashboards::Configurable (project dashboard binding) ---
  def editor_widget_registry
    Dashboards::LayoutEngine::WIDGET_REGISTRY
  end

  def editor_base_params
    { project: @project, user: current_user }
  end

  def editor_configuration(layout)
    config = DashboardConfiguration.for_user_project(current_user, @project)
    config.organisation = @current_organisation
    config.layout = layout
    config
  end

  # Whitelisted save target. Non-admins can never reach a `default_*` scope:
  # those write the shared project default, so they fall back to a personal save.
  def save_scope
    scope = params[:save_scope].presence_in(SAVE_SCOPES) || 'personal_this'
    return 'personal_this' if scope.start_with?('default_') && !current_user.account_admin_in?(@current_organisation)

    scope
  end

  # The _all notices report how many projects were written; the actor materialised the
  # relation, so .size is free here (and projects is never loaded for the _this scopes).
  def saved_notice(scope, projects)
    case scope
    when 'default_all'  then t('dashboard.configuration.saved_as_default_all', count: projects.size)
    when 'personal_all' then t('dashboard.configuration.saved_personal_all', count: projects.size)
    when 'default_this' then t('dashboard.configuration.saved_as_default')
    else                     t('dashboard.configuration.saved')
    end
  end

  def load_edit_data
    @available_widgets = Dashboards::LayoutEngine.available_widgets_for(current_user, @project)
    @smart_folders = policy_scope(@project.smart_folders).where(target_object_type: %w[Ticket All]).order(:name)
    @is_admin = current_user.account_admin_in?(@current_organisation)
  end
end
