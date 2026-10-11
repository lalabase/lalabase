# frozen_string_literal: true

# Keeps every organisation with at least one active account admin: nobody else
# can manage members, roles or billing there. The one owner of that rule for
# demoting or deactivating a membership (MembershipsController#update),
# removing one (RemoveMembershipService) and deleting one's own account
# (DeleteAccountService).
#
# An admin counts when the membership is active and the account can sign in
# (users.active, not soft-deleted). Admins may still demote each other; only
# the change that would leave nobody is refused.
#
# Entry point: blocks?, organisations_left_without_admin
module Memberships
  class LastAdminGuard
    # True when the pending change to `membership` (assigned, not yet saved)
    # or its removal would leave its organisation without an active admin.
    def self.blocks?(membership, removing: false)
      return false unless active_admin_before_change?(membership)
      return false if !removing && active_admin_after_change?(membership)

      !other_active_admin?(membership)
    end

    # The organisations in which `user` is the last active admin, for deleting
    # the whole account.
    def self.organisations_left_without_admin(user)
      user.memberships.active.includes(:organisation).select { |membership| blocks?(membership, removing: true) }
          .map(&:organisation)
    end

    def self.active_admin_before_change?(membership)
      return false unless membership.attribute_in_database(:active)

      admin_role_ids(membership.organisation).include?(membership.attribute_in_database(:role_id))
    end

    def self.active_admin_after_change?(membership)
      membership.active? && admin_role_ids(membership.organisation).include?(membership.role_id)
    end

    def self.other_active_admin?(membership)
      Membership.active
                .where(organisation_id: membership.organisation_id, role_id: admin_role_ids(membership.organisation))
                .where.not(id: membership.id)
                .joins(:user).merge(User.active)
                .exists?
    end

    # Role is tenant-scoped; the question is about exactly this organisation.
    def self.admin_role_ids(organisation)
      ActsAsTenant.with_tenant(organisation) do
        Role.where(organisation_id: organisation.id, title: Role::ACCOUNT_ADMIN_TITLE).pluck(:id)
      end
    end

    private_class_method :active_admin_before_change?, :active_admin_after_change?,
                         :other_active_admin?, :admin_role_ids
  end
end
