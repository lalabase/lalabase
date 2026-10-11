# frozen_string_literal: true

# app/services/actors/revoke_project_member.rb
#
# Takes one person off one project. The caller says WHO, this actor decides HOW,
# and it is the only place that may decide it.
#
# Two mechanisms, because dropping the explicit grant is not always enough:
#
#   release  the person has no role-derived right, so soft-deleting their
#            ProjectPermission leaves them without access. The row goes away and
#            they drop back into the add-member picker.
#   block    a global "*_all_projects" role right would take over the moment the
#            grant disappeared. Deleting would report success and change nothing,
#            so instead the grant is kept and set to no_access everywhere, which
#            ProjectAccessService honours OVER the role right.
#
# Why this must not live in the view or the controller: the two mechanisms differ
# only by a fact about the user's ROLE, and a caller that guesses wrong produces a
# green flash over an unchanged project. Team page and dashboard read the same
# fact from AccessCheck::RoleProjectRightsService.
#
# Both mechanisms take the time rights with them (ProjectPermission
# #drop_time_session_permission): they were set on the membership that ends here,
# and a surviving row kept a removed member reading and booking time.
#
# What this actor deliberately does NOT do: touch notification subscriptions,
# assignments or notifications. It used to delete the project subscription, because
# back then FanoutService merged subscribers without re-checking rights and a surviving
# row kept delivering. FanoutService now checks (see #with_current_access there), so the
# deletion has lost its reason and would only do harm: it cannot tell a subscription the
# person had from one they had muted on purpose, and a removal is often temporary. The
# rows stay and stop having an effect; putting the person back on the project brings
# their old state back with no repair step.
module Actors
  class RevokeProjectMember < BaseActor
    def initialize(project:, user:, current_user:)
      super()
      @project = project
      @user = user
      @current_user = current_user
      @permission = nil
      @mechanism = nil
    end

    # The blocking grant survives; a release leaves nothing behind.
    def record
      @mechanism == :block ? @permission : nil
    end

    # What actually happened, so the caller can tell the user the truth.
    attr_reader :mechanism

    def perform
      guard_admin!
      guard_membership!

      @mechanism = role_takes_over? ? :block : :release
      @mechanism == :block ? block_every_area : release_grant

      track
    end

    private

    attr_reader :project, :user

    def organisation
      project.organisation
    end

    # An account admin holds full write on every project of the org, and no
    # per-project row can override that (ProjectAccessService checks admin first).
    # Pretending otherwise would be the same lie this actor exists to remove.
    def guard_admin!
      return unless user.account_admin_in?(organisation)

      raise ActorError.new(I18n.t('flash.project_permissions.admin_cannot_be_revoked'),
                           code: :admin_cannot_be_revoked)
    end

    # Nothing to revoke means nothing to write. Without this, a stray request
    # would leave a blocking row on someone who was never on the project.
    def guard_membership!
      return if existing_permission || role_takes_over?

      raise ActorError.new(I18n.t('flash.project_permissions.not_a_member'), code: :not_a_member)
    end

    def role_takes_over?
      return @role_takes_over if defined?(@role_takes_over)

      @role_takes_over = AccessCheck::RoleProjectRightsService.grants_any_project_right?(user, organisation)
    end

    def existing_permission
      return @existing_permission if defined?(@existing_permission)

      @existing_permission = project.project_permissions.find_by(user_id: user.id)
    end

    # Revive an archived row rather than inserting a second one: the unique index
    # on (user_id, project_id) counts soft-deleted rows too.
    def block_every_area
      @permission = existing_permission ||
                    ProjectPermission.archived_for(project: project, user: user) ||
                    project.project_permissions.new(user: user)

      # A blocking row must not subscribe the person it locks out; see
      # ProjectPermission#skip_auto_subscribe. Only the create path needs this,
      # but setting it unconditionally keeps the three branches above equal.
      @permission.skip_auto_subscribe = true
      @permission.deleted_at = nil
      ProjectPermission.access_areas.each { |area| @permission.public_send("#{area}_access=", 'no_access') }
      @permission.save!
      # The row stays alive, so its soft-delete callback does not fire here.
      @permission.drop_time_session_permission
    end

    def release_grant
      @permission = existing_permission
      @permission.update!(deleted_at: Time.current)
    end

    # Both mechanisms end with the same fact about the project: this person is off
    # it. The reason keeps the two apart in the trail.
    def track
      user.track_project_access_revoke(project, revoked_by: current_user)
      project.track_member_removed(user, @mechanism == :block ? 'role_right_blocked' : nil)
    end
  end
end
