# frozen_string_literal: true

# Org-wide prompt library housekeeping (Gespräche Slice 7a, Eng-Review 6A). Only
# destroy: a trivial write (one delete, the FK nullifies analysis_prompt_id on
# existing analyses which keep their snapshot), so per the seam rule it lives in a
# controller, not an actor. Nested under the meeting for the write context
# (meetings-write); the prompt itself is org-wide. Since #817 this only serves an
# already-open legacy form; current deletion is AssistantAnalysisPromptsController#destroy.
# Prompt EDIT is deliberately v2 (§8).
module Organisations
  class AnalysisPromptsController < Organisations::BaseController
    include ProjectController
    include MeetingAnalysesStreams

    before_action :set_meeting

    def destroy
      # :meetings write on this project (MeetingPolicy#update?). meetings-write may
      # curate the org library.
      authorize @meeting, :update?

      # Tenant-scoped: a foreign-org prompt id is simply not found → friendly no-op.
      AnalysisPrompt.where(organisation: @current_organisation).find_by(id: params[:id])&.destroy

      respond_to do |format|
        # Transition path for an already-open legacy form. Do not reinsert the
        # removed compose surface; current management lives in the assistant.
        format.turbo_stream { render turbo_stream: flash_stream('flash.analysis_prompts.deleted') }
        format.html do
          redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_id: @meeting.id),
                      notice: t('flash.analysis_prompts.deleted')
        end
      end
    end

    private

    # See MeetingAnalysesController — "analysis_prompts" would auto-map to a
    # non-existent :analysis_prompt area and deny everyone.
    def determine_access_area
      :meetings
    end

    def set_meeting
      @meeting = @project.meetings.find(params[:meeting_id])
    end
  end
end
