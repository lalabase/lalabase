# frozen_string_literal: true

module Organisations
  class OrganisationSettingsController < BaseController
    before_action :set_inbox_project_choices

    def show
      authorize @current_organisation, :update?
    end

    def update
      authorize @current_organisation, :update?

      if @current_organisation.update(organisation_settings_params)
        redirect_to organisation_settings_path(@current_organisation),
                    notice: t('flash.organisation_settings.saved')
      else
        render :show, status: :unprocessable_entity
      end
    end

    private

    def organisation_settings_params
      # Subdomain/domain are parked (custom-access-domain feature deferred); the form no
      # longer exposes them, so we do not accept them via mass-assignment either. Re-add
      # `:subdomain, :domain` here when the fields return to the settings view.
      params.require(:organisation).permit(:name, :meeting_inbox_project_id)
    end

    # The active projects, plus the stored one when it is archived: left out, the
    # select would submit nothing for it and every save of this form would clear
    # an inbox that comes back on restore.
    def set_inbox_project_choices
      stored = @current_organisation.meeting_inbox_project_id
      @inbox_project_choices = @current_organisation.projects.where(archived_at: nil).or(
        @current_organisation.projects.where(id: stored)
      ).order(:name)
    end
  end
end
