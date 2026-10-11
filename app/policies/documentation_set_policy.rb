# frozen_string_literal: true

# Authorization for DocumentationSet records. Read = browse (:documentation
# read); write = manage the connection and trigger a manual sync (:documentation
# read_write). The Scope keeps listings to sets the user may read.
class DocumentationSetPolicy < ApplicationPolicy
  def index?
    area_read?
  end

  def show?
    area_read?
  end

  def create?
    area_write?
  end

  def new?
    create?
  end

  def update?
    area_write?
  end

  def edit?
    update?
  end

  def destroy?
    area_write?
  end

  def sync?
    area_write?
  end

  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)
      return scope.where(project_id: Project.active.select(:id)) if reads_all_documentation?

      # Revoked permissions are excluded implicitly: ProjectPermission soft-
      # deletes via default_scope { deleted_at: nil }. Do NOT switch this query
      # to .unscoped/.with_deleted — revoked users would silently regain
      # visibility (guarded by a policy spec).
      # An archived project is the admins' alone (AccessCheck::ProjectAccessService).
      readable_project_ids = ProjectPermission
                             .where(user_id: user.id)
                             .where.not(documentation_access: :no_access)
                             .where(project_id: Project.active.select(:id))
                             .select(:project_id)
      scope.where(project_id: readable_project_ids)
    end

    private

    # Admins and holders of the org-wide role grant read every project's docs;
    # everyone else is limited to their per-project permission rows.
    def reads_all_documentation?
      user.account_admin_in?(organisation) ||
        user.has_permission_in_organisation?(organisation, 'projects', 'read_access_documentation_all_projects') ||
        user.has_permission_in_organisation?(organisation, 'projects', 'write_access_documentation_all_projects')
    end
  end

  private

  def project
    record.is_a?(DocumentationSet) ? record.project : record
  end

  def area_read?
    ProjectPolicy.new(user, project).area_access?(:documentation, :read)
  end

  def area_write?
    ProjectPolicy.new(user, project).area_access?(:documentation, :write)
  end
end
