# frozen_string_literal: true

# Being the account owner != automatic access to org data (D4,
# doc/billing_agentur_konto_plan.md). Separate from the OrganisationPolicy/
# ProjectPermission chain: whoever owns the account manages billing and the
# org assignment, but is NOT automatically an admin in the organisations
# that belong to it.
class AccountPolicy < ApplicationPolicy
  # Invoice address, VAT ID, billing e-mail: owner only, reading AND writing
  # (E6). In the agency case those are the master data of a different legal
  # entity, and the org admin of one bundled customer org has no business
  # reading them.
  def manage_billing?
    owner?
  end

  # Seats and the bundled organisations: readable for every active
  # account_admin of a bundled org (E6, cost transparency).
  #
  # Reuses Account#eligible_owner? deliberately: "may claim this account" and
  # "may read the overview" are the SAME rule today (active account_admin of a
  # bundled org, globally active, not soft-deleted), including the per-org
  # with_tenant handling that Role's tenant scope forces. They are NOT the same
  # CONCEPT -- if claim eligibility ever changes, split them instead of quietly
  # shifting read visibility.
  def show_overview?
    owner? || record.eligible_owner?(user)
  end

  # NOT YET WIRED UP (Phase 1 scope, same status as RolePolicy#update_billable?
  # and #claim?): no controller consumes this until an org-assignment/merge
  # flow exists (merging existing organisations into one account, not built yet).
  # Kept so that the first PR wiring it authorizes against the correct
  # owner-only check instead of inventing its own.
  def manage_orgs?
    owner?
  end

  # D11: an orphan Account (owner: nil, s. D8) can be claimed by an active
  # account_admin of one of its organisations. Eligibility -- active membership +
  # account_admin role + globally active + not soft-deleted (D9) -- lives in
  # Account#eligible_owner?, the single source shared with the Admin assign_owner
  # guard (see there for why each org is checked under its own tenant). This is
  # the "who is allowed" check; Account#claim! separately guards the "not already
  # owned" invariant.
  def claim?
    return false if record.owner.present?

    record.eligible_owner?(user)
  end

  private

  # D9 applies to the OWNER branch too, and it did not until 2026-08-06.
  #
  # #eligible_owner? has always hoisted "globally active and not soft-deleted"
  # above its per-org loop, so the account_admin branch was covered. The owner
  # branch was a bare id comparison, which meant a deactivated owner kept full
  # billing access -- reading AND writing the master data, and through
  # RolePolicy#update_billable? the seat price of every bundled organisation.
  # Deactivating somebody has to take the money with it.
  #
  # `active: false` was the half that was demonstrably reached: until
  # 27.09.2026 Devise's active_for_authentication? ignored users.active, so such
  # a user signed in normally (measured: the account page answered 200 before
  # this guard, 302 after). It now signs them out (User::SystemAccount); this
  # guard stays for callers that ask without a session. The soft-deleted case is covered for symmetry rather than
  # because it was reachable -- SoftDeletable's default scope means the session
  # cannot deserialise that user at all.
  #
  # Found because Subscriptions::VisibleAccounts applies the invariant to both
  # branches and the two answers disagreed: the account summary listed nothing
  # while the account page itself rendered in full. The disagreement was the
  # symptom, this was the defect.
  def owner?
    return false unless active_user?

    record.owner_id.present? && record.owner_id == user.id
  end

  # Same three conditions as the guard at the top of Account#eligible_owner?,
  # deliberately spelled the same way so the two cannot drift.
  #
  # The `user.present?` half is dead in THIS application: ApplicationPolicy#initialize
  # raises Pundit::NotAuthorizedError on a nil user before any predicate runs. It is
  # kept because it costs nothing and because #eligible_owner? carries it too, and
  # a reader comparing the two should not have to work out why they differ. Do not
  # read it as evidence that anonymous callers reach here; they do not.
  def active_user?
    user.present? && user.active? && user.deleted_at.nil?
  end
end
