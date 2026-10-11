# frozen_string_literal: true

module Organisations
  class SidebarPinsController < BaseController
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped

    def update
      project = current_organisation.projects.find_by(id: params[:project_id])
      return head :not_found if project.nil? || !policy(project).show?

      toggle_pin(project)

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'sidebar-project-list',
            partial: 'common/sidebar_project_list'
          )
        end
        format.html { redirect_to organisation_root_path(organisation_id: current_organisation.id) }
      end
    end

    private

    def toggle_pin(project)
      section = params[:section].presence

      if section
        if current_user.sidebar_pins.pinned_sections_for(current_organisation, project.id).include?(section)
          current_user.sidebar_pins.unpin_section!(current_organisation, project.id, section)
        else
          current_user.sidebar_pins.pin_section!(current_organisation, project.id, section)
        end
      elsif current_user.sidebar_pins.project_pinned?(current_organisation, project.id)
        current_user.sidebar_pins.unpin_project!(current_organisation, project.id)
      else
        current_user.sidebar_pins.pin_project!(current_organisation, project.id)
      end
    end
  end
end
