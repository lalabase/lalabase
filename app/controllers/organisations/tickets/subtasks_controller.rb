# frozen_string_literal: true

# Inline quick-add of sub-tasks. Deliberately lean (eng-review decision): it does NOT inherit the
# heavy Organisations::TicketsController (ObjectListController, sorting, search, ~8 before_actions)
# — only what a single create needs. Routing through Actors::SaveTicket keeps assignee sync,
# activity tracking and embeddings identical to the normal ticket-create path.
#
# The parent comes from the URL (:ticket_id), scoped to @project, so a tampered/cross-tenant
# parent is a 404 here (set_parent) before any write — the model's same-project validation is the
# second line of defence.
class Organisations::Tickets::SubtasksController < Organisations::BaseController
  include TicketListColumns

  before_action :set_project
  before_action :set_parent
  before_action :authorize_subtask_create

  # POST /org/:organisation_id/projects/:project_id/tickets/:ticket_id/subtasks
  def create
    # Was the parent childless before this add? If so the page shows only the compact empty-state
    # affordance (no list to append to), so the first child swaps the whole section for the populated
    # layout (create_first). Subsequent adds use a targeted append that preserves the input's focus.
    first_child = !@parent.children.exists?

    result = Actors::SaveTicket.call(
      project: @project,
      params: { title: params.permit(:title)[:title], parent_id: @parent.id },
      current_user: current_user
    )
    @child = result.resource
    # One status definition for the appended row's chip (single query, mirrors the section).
    @status_def = @project.ticket_attribute_definitions.detect { |ad| ad.name == 'status' && ad.active }

    if result.success?
      render(first_child ? :create_first : :create)
    else
      @errors = result.errors
      render :create_error, status: :unprocessable_entity # create_error.turbo_stream.erb
    end
  end

  private

  def set_project
    @project = Project.find(params[:project_id])
  end

  def set_parent
    @parent = @project.tickets.find(params[:ticket_id])
  end

  # Same gate as tickets#create (write permission for tickets in the project). The authorize call
  # also satisfies BaseController's after_action :verify_authorized; an unauthorized user raises
  # Pundit::NotAuthorizedError -> handled centrally (flash + redirect).
  def authorize_subtask_create
    authorize @project.tickets.build, :create?
  end
end
