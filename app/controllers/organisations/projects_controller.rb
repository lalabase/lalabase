# frozen_string_literal: true

class Organisations::ProjectsController < Organisations::BaseController
  include Sortable
  include PerformanceOptimized

  class_attribute :default_sort_column
  self.default_sort_column = 'projects.created_at'
  SORTABLE_COLUMNS = Project.column_names

  before_action :set_project, only: %i[show edit details update destroy archive unarchive create_default_attributes]

  # index only redirects to the briefing (org root) — no policy scoping needed.
  skip_after_action :verify_policy_scoped, only: :index

  def index
    # The global project overview is now the briefing dashboard (org root).
    redirect_to organisation_root_path(@current_organisation)
  end

  def show
    @project = Project.find(params[:id])

    # Use Pundit for the permission check
    authorize @project, :show?

    # Dashboard layout from the cascade: user config -> project default -> system default.
    # Each widget component loads its own data self-contained. `owned` tells the render whether
    # this is the user's OWN config (held placeholders for missing rights) or an inherited default
    # (silently filtered per viewer) — see Dashboards::LayoutEngine.resolve_layout_with_source.
    resolution = Dashboards::LayoutEngine.resolve_layout_with_source(current_user, @project)
    @dashboard_layout = resolution.layout
    @dashboard_layout_owned = resolution.owned
  rescue Pundit::NotAuthorizedError
    redirect_to organisation_projects_path(@current_organisation), alert: t('flash.shared.no_project_access')
  end

  def new
    @project = Project.new
    authorize @project, :create?
  end

  def create
    @project = Project.new(project_params)
    authorize @project, :create?

    if @project.save
      if params[:create_default_attributes] == '1'
        Projects::DefaultAttributeService.new(@project).call
        Projects::DefaultSmartFolderService.new(@project).call(current_user)
      end
      redirect_to organisation_projects_path(@current_organisation), notice: t('flash.projects.created')
    else
      # 422, or Turbo Drive drops the response and the user sees nothing happen.
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @project, :update?
  end

  # Name + description form — the settings page (edit) is a pure hub of
  # navigation cards, so the form lives on this subpage.
  def details
    authorize @project, :update?
  end

  def update
    authorize @project, :update?

    if @project.update(project_params)
      redirect_to edit_organisation_project_path(@current_organisation, @project), notice: t('flash.projects.updated'), status: :see_other
    else
      render :details, status: :unprocessable_entity
    end
  end

  def archive
    # Mirror of the stale case in #unarchive, and it is the likelier one: the back
    # button after archiving shows the cached settings page with its "Archivieren"
    # button intact. #archive? answers false for an already archived project, which
    # Pundit would turn into "nicht berechtigt" for someone who is allowed and simply
    # acted on a stale page.
    if @project.archived?
      return redirect_to organisation_project_path(@current_organisation, @project),
                         notice: t('flash.projects.already_archived', name: @project.name)
    end

    authorize @project, :archive?
    @project.archive!(current_user)
    archived_count = Notification.where(project_id: @project.id).inbox.bulk_transition!(
      state: :archived, archived_at: Time.current
    )
    # Where the project WENT, for whoever may look: the archive page teaches the way
    # back on the first archive. But #archive? also passes a non-admin carrying
    # change_project_properties, and the archive page is account-admin only - sending
    # them there would answer a correct action with "nicht berechtigt".
    target = if policy(@current_organisation).admin?
               organisation_archives_path(@current_organisation)
             else
               organisation_projects_path(@current_organisation)
             end

    redirect_to target,
                notice: t('flash.projects.archived', name: @project.name, count: archived_count)
  end

  def unarchive
    # #unarchive? answers false for a project that is no longer archived, and Pundit
    # turns that into "nicht berechtigt" - the wrong answer for an admin whose archive
    # page went stale while someone else restored the same project. So the stale case
    # is answered before that question is asked.
    #
    # The org-level gate comes FIRST anyway: set_project only authorized :show?, which
    # a plain member passes for a project that is not archived. Without this they would
    # get the admin-flavoured "war bereits wiederhergestellt" instead of a refusal.
    authorize @current_organisation, :admin?

    unless @project.archived?
      return redirect_to organisation_archives_path(@current_organisation),
                         notice: t('flash.projects.already_restored', name: @project.name)
    end

    authorize @project, :unarchive?
    @project.unarchive!
    redirect_to organisation_project_path(@current_organisation, @project),
                notice: t('flash.projects.restored', name: @project.name)
  end

  def create_default_attributes
    authorize @project, :update?
    Projects::DefaultAttributeService.new(@project).call
    redirect_to edit_organisation_project_path(@current_organisation, @project),
                notice: t('flash.projects.default_attributes_created')
  end

  def destroy
    authorize @project, :destroy?
    project_name = @project.name
    ProjectDeletionJob.perform_later(@project.id, @project.organisation_id, current_user.id)
    redirect_to organisation_projects_path(@current_organisation),
                notice: t('flash.projects.deleting', name: project_name)
  end

  # Expose flat, permitted sort parameters for specs and Sortable integration
  def sort_params
    return ActionController::Parameters.new unless params[:sort].present?

    params.require(:sort).permit(:column, :direction, :page, :project_id)
  end

  private

  def set_project
    @project = Project.find(params[:id])
    @current_project = @project

    # Use Pundit for the permission check
    authorize @project, :show?
  rescue Pundit::NotAuthorizedError
    redirect_to organisation_projects_path(@current_organisation), alert: t('flash.shared.no_project_access')
  end

  def project_params
    params.require(:project).permit(:name, :description)
  end
end
