# frozen_string_literal: true

# Shared by Organisation and Admin::Organisation (Plan
# doc/billing_agentur_konto_plan.md D8). Both classes map to the same
# `organisations` table but are otherwise deliberately separate models
# (Admin::Organisation exists to bypass acts_as_tenant for cross-tenant admin
# operations, s. app/models/admin/organisation.rb) -- their save cycles never
# share code, so a plain `Organisation`-only callback would silently miss
# every organisation created through the admin path
# (Actors::CreateUserWithOrganisation uses Admin::Organisation, NOT
# Organisation). This concern is included in both, so the SAME auto-account
# logic runs regardless of which class performs the create.
module AccountAutoAssignable
  extend ActiveSupport::Concern

  included do
    # Builds (does NOT persist) a 1:1 Account so it saves atomically together
    # with the organisation via belongs_to autosave. If the organisation
    # itself later fails its own validation (e.g. blank/duplicate name),
    # nothing is ever persisted for either record -- avoids orphan Accounts
    # from a naive `Account.create!` inside this callback.
    before_validation :ensure_account, on: :create
  end

  private

  # Current.user is the owner when present (real requests, s. Actor-Pattern
  # in CLAUDE.md); stays nil for factories/rake tasks and for every write
  # through this admin path (app/services/actors/create_user_with_organisation.rb
  # documents that its actor is a Beuser and therefore never assigns
  # Current.user). For the admin-create path the actor now sets the owner right
  # AFTER this callback (D11: account.update!(owner_id:)), so it is no longer an
  # orphan source; factories/rake tasks still produce owner-less, claimable
  # Accounts, which is an accepted state (s. Account#claim!).
  def ensure_account
    return if account.present?

    self.account = ::Account.new(name: name.presence || I18n.t('shared.account.default_name'), owner: Current.user)
  end
end
