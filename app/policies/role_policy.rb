# frozen_string_literal: true

class RolePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      # Account admins can see all roles
      return scope.all if user.account_admin_in?(organisation)

      # Users with permission to manage roles
      return scope.all if user.has_permission_in_organisation?(organisation, 'accounts', 'add_edit_delete_roles')

      # Other users cannot see any roles
      scope.none
    end
  end

  def index?
    account_admin? || has_permission?('accounts', 'add_edit_delete_roles')
  end

  def show?
    account_admin? || has_permission?('accounts', 'add_edit_delete_roles')
  end

  def create?
    account_admin? || has_permission?('accounts', 'add_edit_delete_roles')
  end

  # A role manager who is no account admin does not edit their own role:
  # otherwise the right to edit roles is the right to every other right.
  def update?
    return false if record.title == 'account_admin' && !account_admin?
    return false if !account_admin? && own_role?

    account_admin? || has_permission?('accounts', 'add_edit_delete_roles')
  end

  # Whether this user may change ONE right on a role, granting or removing it.
  # Only a right they hold themselves (account admins hold all). Removing counts
  # too: a manager must not strip other roles of rights beyond their own reach.
  # Enforced by Actors::SaveRole for every right the form actually changes.
  def change_permission?(category, action)
    account_admin? || Permission.granting_actions(category, action).any? { |granting| has_permission?(category, granting) }
  end

  def destroy?
    # The account_admin role cannot be deleted
    return false if record.title == 'account_admin'

    account_admin? || has_permission?('accounts', 'add_edit_delete_roles')
  end

  # Custom method to check whether a user can change the default role
  # Every new member gets the default role, so making a role the default hands
  # out its rights. A manager may only pick a role whose rights they hold.
  def set_default?
    return true if account_admin?
    return false unless has_permission?('accounts', 'add_edit_delete_roles')

    record.permissions.select(&:allowed).all? { |permission| change_permission?(permission.category, permission.action) }
  end

  # D10 (Codex-Fund): without its own check, `billable` would be a cost bypass
  # -- ANY org-admin (role-editing is a standard admin right) could set every
  # role to billable: false. Deliberately checked against AccountPolicy#manage_billing?
  # instead of the normal role-editing permission (account_admin?/has_permission?
  # above), so changing this flag requires Account-Owner-Sein, not Org-Admin-Sein.
  #
  # NOT YET WIRED UP (Phase 1 / T6 scope): no controller calls this today --
  # RolesController#role_params does not permit :billable at all (s. the
  # guard-rail comment there). This method exists so the FIRST future PR that
  # adds a billable checkbox to the roles UI has the correct check ready to
  # authorize against, instead of reaching for the easier-looking (but wrong)
  # `authorize @role` alone.
  def update_billable?
    return false unless organisation&.account

    AccountPolicy.new(user, organisation.account).manage_billing?
  end

  private

  def own_role?
    organisation.present? && user.role_in_organisation(organisation)&.id == record.id
  end
end
