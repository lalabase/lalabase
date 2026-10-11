# frozen_string_literal: true

# The accounts a user has any business seeing (K4 of doc/konto_ebene_plan.md):
# the ones they own, plus the ones where they are an active account_admin of a
# bundled organisation. That is the same rule as AccountPolicy#show_overview?,
# resolved ONCE for a whole page instead of once per row.
#
# NOT a scope on Account, deliberately: the rule is an authorisation question
# rather than a database filter, and it needs the per-organisation with_tenant
# handling that Role's tenant scope forces.
#
# THE INVERSION IS THE POINT. AccountPolicy#show_overview? asks the account
# ("does any of MY organisations carry this user as an account_admin?") and
# therefore walks account.organisations. Asked once per row that walk fans out
# over rows x organisations-of-the-account, which is lesson #368 and the cost
# shape E10 already ran into. This class asks the USER instead ("which of the
# organisations I am a member of make me an account_admin?"), which is bounded
# by the user's own memberships and does not grow when somebody else's account
# bundles more organisations. Both questions have the same answer: an
# organisation can only make the user eligible if the user is a member of it.
#
# The D9 invariants (globally active, not soft-deleted) are checked here for the
# same reason Account#eligible_owner? hoists them: a user who can never sign in
# must not appear as eligible anywhere. They apply to BOTH branches, owner
# included -- which is what surfaced the missing invariant in
# AccountPolicy#owner? (see the comment there). The two answers have to agree,
# and spec/services/subscriptions/visible_accounts_spec.rb checks that they do,
# for the deactivated and soft-deleted owner specifically.
module Subscriptions
  class VisibleAccounts
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      return Account.none unless eligible_user?

      # Preloads what every caller renders next: the bundled organisations (name
      # per row) and the discounts, which AmountPreview then filters in memory
      # instead of querying per account.
      Account.where(id: owned_account_ids | admin_account_ids)
             .includes(:organisations, :discounts)
             .order(:name)
    end

    private

    # Mirrors the first half of Account#eligible_owner?: an inactive or
    # soft-deleted user is eligible nowhere, so this returns before a single
    # membership query is issued. Ownership is checked against the same guard on
    # purpose -- an account whose owner has been deactivated must not stay
    # readable through the owner branch either.
    def eligible_user?
      @user.present? && @user.active? && @user.deleted_at.nil?
    end

    def owned_account_ids
      Account.where(owner_id: @user.id).pluck(:id)
    end

    # One role lookup per organisation THE USER belongs to. Role is
    # acts_as_tenant(:organisation), so its title only resolves under that
    # organisation's own tenant -- and the cockpit, the main caller, runs without
    # one. #account_admin_in? goes through the request-level role cache, so a
    # second caller on the same request pays nothing.
    def admin_account_ids
      @user.active_organisations.filter_map do |organisation|
        next if organisation.account_id.nil?

        organisation.account_id if ActsAsTenant.with_tenant(organisation) { @user.account_admin_in?(organisation) }
      end
    end
  end
end
