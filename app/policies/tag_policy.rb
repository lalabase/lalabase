# frozen_string_literal: true

class TagPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    account_admin? || visible_to_user?
  end

  def create?
    user.present?
  end

  def update?
    user.present? && (record.user_id == user.id || account_admin?)
  end

  def destroy?
    user.present? && (record.user_id == user.id || account_admin?)
  end

  class Scope < Scope
    # Org admins see every tag (including unused ones). Everyone else only sees tags that
    # are actually used in a project they can access — so the tag list and its JSON
    # autocomplete never leak foreign-project tag names.
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      accessible_project_ids =
        AccessCheck::ProjectAccessService.accessible_projects(user, organisation).select(:id)
      scope.used_in_projects(accessible_project_ids)
    end
  end

  private

  # Defence in depth next to set_tag's policy_scope(Tag).find: a tag is only viewable if
  # it falls inside the user's scoped tag set.
  def visible_to_user?
    Scope.new(user, Tag).resolve.exists?(id: record.id)
  end
end
