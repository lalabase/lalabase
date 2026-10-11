# frozen_string_literal: true

# == Schema Information
#
# Table name: time_session_permissions
#
#  id             :uuid             not null, primary key
#  can_create_own :boolean          default(TRUE), not null
#  can_delete_all :boolean          default(FALSE), not null
#  can_delete_own :boolean          default(TRUE), not null
#  can_edit_all   :boolean          default(FALSE), not null
#  can_edit_own   :boolean          default(TRUE), not null
#  can_view_all   :boolean          default(FALSE), not null
#  can_view_own   :boolean          default(TRUE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  project_id     :uuid             not null
#  user_id        :uuid             not null
#
# Indexes
#
#  index_time_session_permissions_on_project     (project_id)
#  index_time_session_permissions_on_project_id  (project_id)
#  index_time_session_permissions_on_user_id     (user_id)
#  index_time_session_permissions_unique         (user_id,project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
class TimeSessionPermission < ApplicationRecord
  belongs_to :user
  belongs_to :project

  validates :user_id, uniqueness: { scope: :project_id }

  # THE door for every reader of time rights: a row counts only while a live
  # ProjectPermission for the same person and project stands behind it. The time
  # row is a second grant on top of project membership, and until 27.09.2026 it
  # outlived the membership it was set on (Actors::RevokeProjectMember, the
  # Team page, a soft delete). The rows now go with the membership
  # (ProjectPermission#drop_time_session_permission, Membership), and this
  # scope keeps rows left over from before that from counting.
  # Guard: spec/architecture/time_session_permission_guard_spec.rb.
  scope :backed_by_project_access, lambda {
    live_grant = ProjectPermission.unscoped
                                  .where(deleted_at: nil)
                                  .where('project_permissions.user_id = time_session_permissions.user_id')
                                  .where('project_permissions.project_id = time_session_permissions.project_id')
    where(live_grant.arel.exists)
  }

  # Scope for organisation
  scope :for_organisation, ->(org) { joins(:project).where(projects: { organisation_id: org.id }) }

  # Defaults for new permissions
  after_initialize :set_defaults, if: :new_record?

  def set_defaults
    self.can_create_own = true if can_create_own.nil?
    self.can_view_own = true if can_view_own.nil?
    self.can_edit_own = true if can_edit_own.nil?
    self.can_delete_own = true if can_delete_own.nil?
    self.can_view_all = false if can_view_all.nil?
    self.can_edit_all = false if can_edit_all.nil?
    self.can_delete_all = false if can_delete_all.nil?
  end

  # Helper for Policy
  def can?(action, scope = :own)
    case [action.to_sym, scope.to_sym]
    when %i[create own] then can_create_own?
    when %i[view own] then can_view_own?
    when %i[edit own] then can_edit_own?
    when %i[delete own] then can_delete_own?
    when %i[view all] then can_view_all?
    when %i[edit all] then can_edit_all?
    when %i[delete all] then can_delete_all?
    else false
    end
  end

  # Overview of the rights as text
  def permission_summary
    permissions = []
    permissions << I18n.t('models.time_session_permission.labels.create_own') if can_create_own?
    permissions << I18n.t('models.time_session_permission.labels.view_own') if can_view_own?
    permissions << I18n.t('models.time_session_permission.labels.edit_own') if can_edit_own?
    permissions << I18n.t('models.time_session_permission.labels.delete_own') if can_delete_own?
    permissions << I18n.t('models.time_session_permission.labels.view_all') if can_view_all?
    permissions << I18n.t('models.time_session_permission.labels.edit_all') if can_edit_all?
    permissions << I18n.t('models.time_session_permission.labels.delete_all') if can_delete_all?
    permissions.join(', ')
  end

  # All rights with status (for display with strikethrough)
  def all_permissions_with_status
    {
      I18n.t('models.time_session_permission.labels.create_own') => can_create_own?,
      I18n.t('models.time_session_permission.labels.view_own') => can_view_own?,
      I18n.t('models.time_session_permission.labels.edit_own') => can_edit_own?,
      I18n.t('models.time_session_permission.labels.delete_own') => can_delete_own?,
      I18n.t('models.time_session_permission.labels.view_all') => can_view_all?,
      I18n.t('models.time_session_permission.labels.edit_all') => can_edit_all?,
      I18n.t('models.time_session_permission.labels.delete_all') => can_delete_all?
    }
  end
end
