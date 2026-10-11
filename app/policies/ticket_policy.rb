# frozen_string_literal: true

class TicketPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :tickets
      )
      scope.where(project_id: project_ids)
    end
  end

  def index?
    # For index action on the class level, always return true
    # The actual authorization is done at the project level in the controller
    true
  end

  def show?
    project_policy.area_access?(:tickets, :read) || account_admin?
  end

  def create?
    project_policy.area_access?(:tickets, :write) || account_admin?
  end

  def update?
    project_policy.area_access?(:tickets, :write) || account_admin?
  end

  def destroy?
    account_admin? || has_permission?('tickets', 'delete_tickets')
  end

  def move?
    account_admin? || has_permission?('tickets', 'move_tickets')
  end

  def select?
    show?
  end

  private

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.project)
  end
end
