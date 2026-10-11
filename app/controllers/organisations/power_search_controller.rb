# frozen_string_literal: true

class Organisations::PowerSearchController < Organisations::BaseController
  before_action :set_project_if_provided
  # PowerSearch#index renders a search form (no listing) — Pundit's index policy_scope
  # convention does not apply. Authorization happens via `authorize :power_search`.
  skip_after_action :verify_policy_scoped, only: :index
  after_action :verify_authorized, only: :index

  def index
    authorize :power_search, :index?
  end

  def execute
    authorize :power_search, :execute?
    query = params[:power_search_query]
    project_id = params[:project_id].presence

    service = PowerSearchService.new(query, current_organisation, project_id, current_user)
    @results_with_type = service.execute
    # S3 §4.6: note when the semantic layer was unavailable (AI off / quota) so the
    # results view can show the "ohne KI-Ranking" hint.
    @semantic_degraded = service.semantic_degraded?

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          'main_content',
          partial: 'organisations/power_search/power_search_results',
          locals: { results: @results_with_type }
        )
      end

      format.html { render :index }
    end
  end

  private

  def set_project_if_provided
    # If project_id is present in the parameters, set the current project
    # This allows the project navigation to be shown during search as well
    return unless params[:project_id].present?

    begin
      @current_project = selectable_projects.find(params[:project_id])
      @project = @current_project # For compatibility with ProjectController
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn "PowerSearchController: Project with ID #{params[:project_id]} not found or not accessible"
      # Project not found/no access, but continue with the search anyway
    end
  end
end
