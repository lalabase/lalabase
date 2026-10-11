# frozen_string_literal: true

class OrganisationPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    user_is_member?
  end

  def create?
    true
  end

  def update?
    user_is_admin?
  end

  def destroy?
    user_is_admin?
  end

  def admin?
    user_is_admin?
  end

  def select?
    true
  end

  def set?
    user_is_member?
  end

  class Scope < Scope
    def resolve
      scope.joins(:memberships).where(memberships: { user: user, active: true })
    end
  end

  private

  def user_is_member?
    return false unless record

    user.active_member_of_organisation?(record)
  end

  def user_is_admin?
    return false unless record

    !!user.account_admin_in?(record)
  end
end
