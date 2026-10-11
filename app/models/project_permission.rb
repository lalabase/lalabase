# frozen_string_literal: true

# == Schema Information
#
# Table name: project_permissions
#
#  id                   :uuid             not null, primary key
#  chats_access         :integer          default("no_access"), not null
#  deleted_at           :datetime
#  documentation_access :integer          default("no_access"), not null
#  documents_access     :integer          default("no_access"), not null
#  last_accessed_at     :datetime
#  meetings_access      :integer          default("no_access"), not null
#  members_access       :integer          default("no_access"), not null
#  notes_access         :integer          default("no_access"), not null
#  tickets_access       :integer          default("no_access"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  project_id           :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  index_project_permissions_on_deleted_at              (deleted_at)
#  index_project_permissions_on_user_id_and_project_id  (user_id,project_id) UNIQUE
#  index_project_permissions_on_user_last_accessed      (user_id,last_accessed_at)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
class ProjectPermission < ApplicationRecord
  # Soft-delete with default_scope
  default_scope { where(deleted_at: nil) }

  belongs_to :user
  belongs_to :project

  enum :tickets_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  enum :notes_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  enum :chats_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  enum :documents_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  enum :members_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  # read_write additionally grants the right to trigger a manual doc sync.
  enum :documentation_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  enum :meetings_access, {
    no_access: 0,
    read_only: 1,
    read_write: 2
  }, prefix: true

  # Only active (not deleted) permissions need to be unique
  validates :user_id, uniqueness: { scope: :project_id, conditions: -> { where(deleted_at: nil) } }

  # Set by a writer whose new row is a BLOCK rather than an invitation
  # (Actors::RevokeProjectMember). Subscribing the person you just locked out
  # keeps feeding them project notifications, because
  # Notifications::FanoutService#find_generic_recipients merges Project
  # subscribers WITHOUT re-checking access.
  #
  # Deliberately NOT derived from #grants_nothing?: the add-member picker submits
  # only user_id, so every freshly added member starts all-no_access and IS meant
  # to follow the project from that moment on.
  attr_accessor :skip_auto_subscribe

  # Auto-subscribe user to project notifications when permission is granted.
  # A REVIVED row is a grant too: ProjectPermissionsController#create restores an
  # archived row with update!(deleted_at: nil), which fires no create callback, so
  # without the second hook a member who was removed and added back would silently
  # stop following the project (Actors::RevokeProjectMember drops the
  # subscription on the way out, and nothing handed it back).
  #
  # The two hooks MUST name different methods. ActiveSupport keys the :commit
  # chain by filter, so declaring the same method twice replaces the first
  # declaration instead of adding to it, and the create-time subscription would
  # silently disappear.
  after_create_commit :auto_subscribe_user, unless: :skip_auto_subscribe
  after_update_commit :auto_subscribe_revived_user, if: :revived?

  # The time rights are set on this membership (Team page, "Zeiterfassung"), so
  # they end with it. Inside the transaction, not after commit: a revoke that
  # rolls back keeps them. A BLOCKING row stays alive, so
  # Actors::RevokeProjectMember calls #drop_time_session_permission itself.
  after_update :drop_time_session_permission, if: :soft_deleted_now?
  after_destroy :drop_time_session_permission

  # The soft-deleted row for this pair, if any. The unique index on
  # (user_id, project_id) covers deleted rows too, so every writer that grants or
  # blocks access has to revive this one instead of inserting a second.
  def self.archived_for(project:, user:)
    unscoped
      .where(project_id: project.id, user_id: user.id)
      .where.not(deleted_at: nil)
      .order(deleted_at: :desc)
      .first
  end

  # All areas with their enum names
  def self.access_areas
    %i[tickets notes chats documents members documentation meetings]
  end

  # Canonical low→high ordering of an access level. Sourced from the (identical for every
  # area) enum integer mapping so it can never drift from the DB encoding.
  def self.level_rank
    @level_rank ||= tickets_accesses.transform_keys(&:to_s).freeze
  end

  # Effective access for `area` given a role-derived fallback `role_level` ('no_access' /
  # 'read_only' / 'read_write'). An explicit no_access is a deliberate block that wins over
  # any role right; otherwise the higher of the explicit grant and the role right applies.
  # This is the ONE place that encodes the "max(explicit, role) unless explicitly blocked"
  # rule — mirrors ProjectAccessService#can? enforcement. (The vestigial #access_level does
  # NOT do this: it ignores the role fallback; aligning or removing it is an open
  # follow-up.)
  def effective_level(area, role_level)
    explicit = public_send("#{area}_access")
    return 'no_access' if explicit == 'no_access'

    rank = self.class.level_rank
    [explicit, role_level].max_by { |level| rank.fetch(level, 0) }
  end

  # Helper methods for the enums in the view
  def self.tickets_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.notes_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.chats_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.documents_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.members_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.documentation_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  def self.meetings_accesses
    { no_access: 0, read_only: 1, read_write: 2 }
  end

  # Did this save bring an archived row back to life? Reads the LAST save only
  # (after_commit's known limit), which holds here because the restore path is a
  # single update!. A blocking write also clears deleted_at, and is kept out by
  # skip_auto_subscribe, which the actor sets on every branch for exactly this.
  def revived?
    !skip_auto_subscribe && saved_change_to_deleted_at? && deleted_at.nil?
  end

  # A grant that gives nothing anywhere. On its own that is only "no rights yet";
  # combined with a role right behind it (see MemberAccess#blocked?) it is a
  # deliberate block, because ProjectAccessService lets no_access beat the role.
  def grants_nothing?
    self.class.access_areas.all? { |area| public_send("#{area}_access") == 'no_access' }
  end

  # Check the access permission
  def can?(action, area)
    return false unless ProjectPermission.access_areas.include?(area.to_sym)

    case action.to_sym
    when :read
      public_send("#{area}_access_read_only?") || public_send("#{area}_access_read_write?")
    when :write
      public_send("#{area}_access_read_write?")
    else
      false
    end
  end

  # Removes this person's time rights on this project (see the callbacks).
  def drop_time_session_permission
    TimeSessionPermission.where(user_id: user_id, project_id: project_id).delete_all
  end

  private

  def soft_deleted_now?
    saved_change_to_deleted_at? && deleted_at.present?
  end

  def auto_subscribe_user
    NotificationSubscription.system_subscribe(user: user, item: project)
  end

  # Distinct name on purpose, see the callback declarations above.
  def auto_subscribe_revived_user
    auto_subscribe_user
  end
end
