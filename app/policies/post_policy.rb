# frozen_string_literal: true

class PostPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :tickets
      )
      scope.joins(:ticket).where(tickets: { project_id: project_ids }).readable_by(user, organisation)
    end
  end

  def show?
    can_access_project = project_policy.area_access?(:tickets, :read) || account_admin?
    return false unless can_access_project

    # One rule for public, addressee, author and admin: Post.readable_by
    record.readable_by?(user)
  end

  def create?
    project_policy.area_access?(:tickets, :write) || account_admin?
  end

  def react?
    show? && create?
  end

  def update?
    can_write_own_post?
  end

  def destroy?
    can_write_own_post?
  end

  private

  def can_write_own_post?
    return false unless project_policy.area_access?(:tickets, :write) || account_admin?

    record.user == user || account_admin?
  end

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.ticket.project)
  end
end
