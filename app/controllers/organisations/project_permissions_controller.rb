# frozen_string_literal: true

class Organisations::ProjectPermissionsController < Organisations::BaseController
  include ProjectController

  skip_before_action :authorize_project_access!
  before_action :authorize_project_permissions

  # ProjectPermissions are authorized via the project (authorize @project),
  # therefore no separate policy scope is necessary
  skip_after_action :verify_policy_scoped, only: [:index]
  skip_after_action :verify_authorized

  def index
    load_members
  end

  def create
    # Org-scoped resolution (unchanged): adding an org member to a project is a members:write
    # action, not a data leak. R3's fix is the grid *display* scoping (assignable_users),
    # which stops enumerating foreign-project identities. Whether non-admins may add *any*
    # org member vs. only visible ones is a separate product decision (see PR body).
    user = current_organisation.users.find(project_permission_params[:user_id])
    permission = find_or_restore_permission(user)

    if permission.persisted? && !permission.changed?
      after_permission_granted(user, permission, :restored)
    elsif permission.save
      after_permission_granted(user, permission, :created)
    else
      load_members
      render :index, status: :unprocessable_entity
    end
  end

  def update
    @project_permission = @project.project_permissions.find(params[:id])

    # Access levels only: the row's user is fixed once it exists. ProjectPermission
    # is not tenant-bound, so a user_id here could hand the row to anyone.
    if @project_permission.update(project_permission_params.except(:user_id))
      track_permission_changes(@project_permission)
      redirect_to permissions_index_path, notice: t('flash.project_permissions.updated')
    else
      # Inline radios can only submit valid enum values, so a validation failure here is
      # near-impossible; fall back to the list with an alert rather than a dead edit page.
      redirect_to permissions_index_path, alert: t('flash.project_permissions.update_failed')
    end
  end

  # "Take this person off the project." The mechanism (drop the grant, or block it
  # because a role right would take over) belongs to the actor, NOT here and not
  # to the view: picking it in the caller is exactly how the button came to report
  # success while changing nothing.
  #
  # Keyed by user_id, because a member who is on the project through their role
  # alone has no permission row to address.
  #
  # No warn_if_guest_ceiling_exceeded call here (unlike #create, via
  # after_permission_granted): revoking project access can only shrink a user's
  # guest project count, never create a new Guest-Ceiling violation.
  def revoke
    user = current_organisation.users.find(params[:user_id])
    actor = Actors::RevokeProjectMember.new(project: @project, user: user, current_user: current_user)
    result = actor.call

    if result.success?
      redirect_to permissions_index_path,
                  notice: t("flash.project_permissions.#{actor.mechanism == :block ? 'blocked' : 'deleted'}")
    else
      redirect_to permissions_index_path, alert: result.errors.first
    end
  end

  # Drops the explicit grant and nothing else, and ONLY when that grant gives
  # nothing. A row that gives nothing can never be the removal path: dropping it
  # can only hand back what the role allows. A row that gives something, dropped
  # here, is exactly the bug this controller was fixed for, because the role right
  # takes over on the next render while the flash reports success. Who leaves a
  # project and how is Actors::RevokeProjectMember's call, reached via #revoke.
  #
  # In practice this is the "lift the block" path: the only caller is the
  # MemberRowComponent's unblock button.
  def destroy
    @project_permission = @project.project_permissions.find(params[:id])
    return refuse_destroy unless @project_permission.grants_nothing?

    user = @project_permission.user
    # Only a role right behind the row makes this a block being lifted; without
    # one the person simply had a grant that gave nothing and now has no row.
    lifting_a_block = AccessCheck::RoleProjectRightsService
                      .grants_any_project_right?(user, current_organisation)

    @project_permission.update!(deleted_at: Time.current)

    # The trail has to match the direction of travel: lifting a block HANDS ACCESS
    # BACK, so recording a revoke there would read as the opposite of what happened.
    if lifting_a_block
      user.track_project_access_grant(@project, granted_by: current_user)
      @project.track_member_added(user, access_details(@project_permission))
    else
      user.track_project_access_revoke(@project, revoked_by: current_user)
      @project.track_member_removed(user)
    end

    redirect_to permissions_index_path,
                notice: t("flash.project_permissions.#{lifting_a_block ? 'block_lifted' : 'deleted'}")
  end

  def time_sessions_settings
    load_time_session_context
  end

  def update_time_sessions_settings
    load_time_session_context

    if @time_permission.update(time_permission_params)
      redirect_to permissions_index_path, notice: t('flash.project_permissions.time_sessions_updated')
    else
      render :time_sessions_settings
    end
  end

  def info
    @organisation = current_organisation
  end

  private

  # #destroy's refusal. Private on purpose: a public method on a controller is an
  # action, and this is a branch of #destroy, not an endpoint of its own.
  def refuse_destroy
    redirect_to permissions_index_path, alert: t('flash.project_permissions.use_revoke_instead')
  end

  # Resolves the project's effective roster (members + add-candidates with provenance)
  # and partitions it. The candidate-set + resolver logic lives in ProjectTeamMembers so
  # this page and the dashboard "TEAM" widget can never drift on who counts as a member.
  # Shared by #index and #create's failure render.
  def load_members
    team = AccessCheck::ProjectTeamMembers.new(project: @project, current_user: current_user)
    # #on_roster owns "who belongs in the table" (access holders plus blocked
    # members, because a block that becomes invisible can never be lifted). #all is
    # memoised, so both reads resolve the roster once.
    @members = team.on_roster
    @candidates = team.all - @members
    @can_manage_members = ProjectPolicy.new(current_user, @project).area_access?(:members, :write)
  end

  def authorize_project_permissions
    policy = ProjectPolicy.new(current_user, @project)

    if action_name == 'index'
      unless policy.area_access?(:members, :read)
        flash[:alert] = t('flash.project_permissions.no_view_permission')
        redirect_to organisation_project_path(current_organisation, @project)
      end
    elsif action_name == 'info'
      unless policy.show?
        flash[:alert] = t('flash.project_permissions.no_view_permission')
        redirect_to organisation_project_path(current_organisation, @project)
      end
    else
      unless policy.area_access?(:members, :write)
        flash[:alert] = t('flash.project_permissions.no_manage_permission')
        redirect_to organisation_project_path(current_organisation, @project)
      end
    end
  end

  def find_or_restore_permission(user)
    archived = ProjectPermission.archived_for(project: @project, user: user)

    if archived
      archived.update!(deleted_at: nil)
      archived
    else
      @project.project_permissions.new(project_permission_params)
    end
  end

  def after_permission_granted(user, permission, flash_key)
    user.track_project_access_grant(@project, granted_by: current_user)
    @project.track_member_added(user, access_details(permission))
    Projects::DefaultSmartFolderService.new(@project).create_my_tasks_for(user)

    warn_if_guest_ceiling_exceeded(user)
    redirect_to permissions_index_path, notice: t("flash.project_permissions.#{flash_key}")
  end

  def track_permission_changes(permission)
    changes = permission.previous_changes.slice(
      'tickets_access', 'notes_access', 'documents_access', 'chats_access', 'documentation_access',
      'meetings_access'
    )
    return if changes.empty?

    @project.track_permission_changed(permission.user, changes.symbolize_keys)
  end

  def access_details(permission)
    {
      tickets_access: permission.tickets_access,
      notes_access: permission.notes_access,
      documents_access: permission.documents_access,
      chats_access: permission.chats_access,
      documentation_access: permission.documentation_access,
      meetings_access: permission.meetings_access
    }
  end

  def load_time_session_context
    @project_permission = @project.project_permissions.find(params[:id])
    @user = @project_permission.user
    @time_permission = @user.time_session_permission_for(@project)
    @organisation = current_organisation
  end

  def permissions_index_path
    organisation_project_project_permissions_path(current_organisation, @project)
  end

  def project_permission_params
    params.require(:project_permission).permit(
      :user_id,
      :tickets_access,
      :notes_access,
      :chats_access,
      :documents_access,
      :members_access,
      :documentation_access,
      :meetings_access
    )
  end

  def time_permission_params
    params.require(:time_session_permission).permit(
      :can_create_own, :can_view_own, :can_edit_own, :can_delete_own,
      :can_view_all, :can_edit_all, :can_delete_all
    )
  end
end
