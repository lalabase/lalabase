# frozen_string_literal: true

# Policy for ViewConfiguration — personal view settings per user/project.
#
# ViewConfigurations are strictly user-owned: No admin bypass, since these are
# personal preferences (column selection, view mode, etc.).
# Cross-tenant protection is additionally ensured by acts_as_tenant at the DB level.
class ViewConfigurationPolicy < ApplicationPolicy
  # Only the owner may edit their config — no admin bypass intended.
  def edit?
    owner?
  end

  def update?
    edit?
  end

  def create?
    ProjectPolicy.new(user, record.project).show?
  end

  class Scope < Scope
    def resolve
      scope.where(user: user)
    end
  end

  private

  def owner?
    record.user_id == user.id
  end
end
