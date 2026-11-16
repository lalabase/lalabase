# frozen_string_literal: true

module Admin
  # PATCH /admin/organisations/:id/subdomain: the instance admin sets the subdomain an
  # organisation is shown under (doc/org_subdomains_plan.md, S1). Nobody in the
  # organisation can; the admin area is Beuser-gated.
  class OrganisationSubdomainsController < Admin::ApplicationController
    def update
      organisation = ::Organisation.find(params[:id])
      result = Actors::AssignOrganisationSubdomain.call(
        organisation: organisation,
        subdomain: params.dig(:organisation_subdomain, :subdomain),
        current_user: nil
      )

      if result.success?
        redirect_to admin_organisation_path(organisation),
                    notice: t('flash.admin.organisations.subdomain_updated', name: organisation.name)
      else
        redirect_to admin_organisation_path(organisation),
                    alert: t('flash.admin.organisations.subdomain_failed', errors: result.errors.to_sentence)
      end
    end
  end
end
