# frozen_string_literal: true

class NotePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :notes
      )
      scope.where(project_id: project_ids)
    end
  end

  def index?
    # For the index action the Note class is authorized, not an instance
    # Access is checked via the before_action :authorize_area_access
    true
  end

  def show?
    project_policy.area_access?(:notes, :read)
  end

  def create?
    project_policy.area_access?(:notes, :write)
  end

  def update?
    project_policy.area_access?(:notes, :write)
  end

  def destroy?
    account_admin? || project_policy.area_access?(:notes, :write)
  end

  private

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.project)
  end
end
