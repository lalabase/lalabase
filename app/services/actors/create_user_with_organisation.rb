# frozen_string_literal: true

# app/services/actors/create_user_with_organisation.rb
#
# Tier-1 actor (admin backend): creates a new user AND bootstraps a fresh organisation
# (account_admin role + membership) for that user, atomically. Reuses OrganisationBootstrap.
#
# Decision D-D: the admin audit actor is a Beuser, not a User. Activity#actor is a User FK
# and the bootstrapped models (Organisation/Role/Membership) are not Trackable, so no
# activity is produced regardless. The actor is therefore called with current_user: nil and
# never sets Current.user to a Beuser. It operates on Admin:: models, which bypass
# acts_as_tenant, so no without_tenant wrapping is needed.
module Actors
  class CreateUserWithOrganisation < BaseActor
    def initialize(user:, organisation:, current_user: nil)
      super()
      @user = user
      @organisation = organisation
      @current_user = current_user
    end

    def record
      @user
    end

    def perform
      @user.save!
      OrganisationBootstrap.call(organisation: @organisation, owner: @user)
      # D11: stop the orphan-Account source on the admin-create path. The account
      # was auto-built owner-less (AccountAutoAssignable: Current.user is nil here,
      # the admin actor is a Beuser). Set the just-created account_admin as owner,
      # atomically inside this actor's transaction. owner_id (not owner:) on
      # purpose: @user is an Admin::User, which is NOT a subclass of User, so a
      # `owner=` belongs_to assignment would raise AssociationTypeMismatch.
      #
      # D9 guard: only an ACTIVE user may own the account. The admin form allows
      # creating a user with active: false ("create now, activate later"); making
      # such a user owner would recreate exactly the state D9 forbids -- an owner
      # who can never sign in, on an Account with NO orphan badge to flag it and
      # no reachable assign_owner UI. Leaving it owner-less keeps it a visible,
      # claimable orphan that the assign_owner UI heals once the user is activated.
      @organisation.account.update!(owner_id: @user.id) if @user.active?
    end
  end
end
