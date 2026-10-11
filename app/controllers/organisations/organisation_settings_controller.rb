# frozen_string_literal: true

module Organisations
  class OrganisationSettingsController < BaseController
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
      params.require(:organisation).permit(:name)
    end
  end
end
