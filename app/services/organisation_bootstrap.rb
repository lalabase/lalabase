# frozen_string_literal: true

# Shared organisation bootstrap step: persist the organisation, ensure its
# account_admin role, and make `owner` an active account_admin member.
#
# Extracted from the previously duplicated logic in OrganisationsController#create
# and Admin::UsersController#create. Duck-typed on purpose so it serves both the
# regular models (Organisation + User) and the tenant-bypassing admin models
# (Admin::Organisation + Admin::User): both respond to #save!,
# #find_or_create_account_admin_role and #memberships.create!.
#
# The caller owns the transaction and any tenant handling — Actors::CreateOrganisation
# (web) wraps this in ActsAsTenant.without_tenant; Actors::CreateUserWithOrganisation
# (admin) relies on the Admin:: models bypassing acts_as_tenant.
#
# The duck-type contract (both model families respond to the trio above) is pinned
# by spec/services/organisation_bootstrap_spec.rb, so a drift in either family
# fails at test time instead of exploding at runtime in the create flow.
class OrganisationBootstrap
  def self.call(organisation:, owner:)
    organisation.save!
    role = organisation.find_or_create_account_admin_role
    owner.memberships.create!(organisation: organisation, role: role, active: true)
    organisation
  end
end
