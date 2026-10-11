# frozen_string_literal: true

class SmartFolderPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    meeting_area_access? && (organisation_admin? || owner? || record.is_public? || shared_with_user?)
  end

  def create?
    !record.respond_to?(:target_object_type) || meeting_area_access?
  end

  def update?
    meeting_area_access? && (organisation_admin? || owner? || shared_with_user?(can_edit: true))
  end

  def destroy?
    organisation_admin? || owner?
  end

  def share?
    meeting_area_access? && (organisation_admin? || owner? || shared_with_user?(can_share: true))
  end

  # Removing somebody else's share: the owner's call or an admin's, like
  # destroy?. A user the folder was shared with may only leave it (show?).
  def manage_shares?
    organisation_admin? || owner?
  end

  # Making a view public (and its public access level) is the owner's call or
  # an admin's: a shared editor must not publish somebody else's private view.
  def publish?
    meeting_area_access? && (organisation_admin? || owner?)
  end

  def clone?
    return false unless meeting_area_access?
    return true if record.is_public? && record.public_copy?

    show?
  end

  class Scope < Scope
    # Privacy contract: a private folder (is_public: false) is visible only to its
    # owner and users it is explicitly shared with — even account admins do NOT see
    # other users' private personal folders in listings. They previously leaked via
    # `scope.all` and surfaced as selectable pills in the ticket filter bar (e.g.
    # another user's "Meine Aufgaben"). Per-record admin powers (show?/update?/
    # destroy?) are unchanged, so admins can still act on a folder by direct reference.
    def resolve
      shared_folder_ids = SmartFolderShare.where(user_id: user.id).select(:smart_folder_id)

      visible = scope.where(user_id: user.id)
                     .or(scope.where(is_public: true))
                     .or(scope.where(id: shared_folder_ids))
                     .distinct
      return visible if user.account_admin_in?(ActsAsTenant.current_tenant)

      meeting_projects = AccessCheck::ProjectAccessService.accessible_project_ids(user, ActsAsTenant.current_tenant, area: :meetings)
      project_ids = meeting_projects.to_a.dup
      project_ids << nil if project_ids.any?
      visible.where.not(target_object_type: 'Meeting').or(visible.where(target_object_type: 'Meeting', project_id: project_ids))
    end
  end

  private

  def meeting_area_access?
    return true unless record.target_object_type == 'Meeting'
    return true if organisation_admin?
    return AccessCheck::ProjectAccessService.accessible_project_ids(user, record.organisation, area: :meetings).any? unless record.project

    AccessCheck::ProjectAccessService.new(user, record.project).can?(:read, :meetings)
  end

  def owner?
    record.user_id == user.id
  end

  def organisation_admin?
    !!user.account_admin_in?(record.organisation)
  end

  def shared_with_user?(**conditions)
    record.smart_folder_shares.exists?({ user_id: user.id }.merge(conditions))
  end
end
