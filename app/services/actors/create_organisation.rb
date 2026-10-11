# frozen_string_literal: true

# app/services/actors/create_organisation.rb
#
# Tier-1 actor: bootstraps a brand-new organisation (org + account_admin role + owner
# membership) in one transaction. A fresh org has no current tenant yet, so the writes
# run inside ActsAsTenant.without_tenant (the membership carries an explicit organisation,
# so nothing relies on a current tenant being set).
#
# The 3-step bootstrap lives in OrganisationBootstrap and is reused by the admin-backend
# actor Actors::CreateUserWithOrganisation.
module Actors
  class CreateOrganisation < BaseActor
    def initialize(organisation:, owner:, current_user:)
      super()
      @organisation = organisation
      @owner = owner
      @current_user = current_user
    end

    def record
      @organisation
    end

    def perform
      ActsAsTenant.without_tenant do
        OrganisationBootstrap.call(organisation: @organisation, owner: @owner)
      end
    end
  end
end
