# frozen_string_literal: true

class MembershipPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.where(organisation: user.organisations) unless @organisation
      return scope.where(organisation: @organisation) if user.account_admin_in?(@organisation)

      # Non-admins see only the people they collaborate with (members of projects they can
      # access) plus org-wide staff (admins/global roles), and always themselves — never the
      # full org roster. So an external single-project user can find their admin contact and
      # project colleagues, but not foreign-project members' names/emails.
      visible_ids = AccessCheck::ProjectAccessService.users_visible_to(user, @organisation).pluck(:id)
      visible_ids << user.id
      scope.where(organisation: @organisation, user_id: visible_ids.uniq)
    end
  end

  def index?
    # Anyone can see the member list of their organisation
    user.present?
  end

  def show?
    # Anyone can see memberships of their organisation
    user_in_same_organisation?
  end

  def edit?
    # Only admins can edit memberships
    user_is_admin?
  end

  def update?
    edit?
  end

  def destroy?
    # Only admins can remove memberships
    # But you cannot remove yourself
    user_is_admin? && record.user_id != user.id
  end

  def manage?
    # For TimeSession permissions management
    user_is_admin?
  end

  private

  def user_in_same_organisation?
    user.organisations.include?(record.organisation)
  end

  def user_is_admin?
    user.account_admin_in?(record.organisation)
  end
end
