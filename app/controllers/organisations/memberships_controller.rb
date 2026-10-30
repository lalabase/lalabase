# frozen_string_literal: true

class Organisations::MembershipsController < Organisations::BaseController
  before_action :authenticate_user!
  def index
    authorize Membership
    load_members
    return if params[:membership_id].blank?

    @membership = policy_scope(Membership).find(params[:membership_id])
    authorize @membership, :edit?
  end

  def show
    @membership = Membership.find(params[:id])
    authorize @membership
  end

  def edit
    @membership = policy_scope(Membership).find(params[:id])
    authorize @membership
    redirect_to organisation_memberships_path(current_organisation, membership_id: @membership.id)
  end

  def update
    @membership = policy_scope(Membership).find(params[:id])
    authorize @membership

    attributes = membership_params
    # Role assignment is restricted to this organisation, including direct PATCH requests.
    policy_scope(Role).find(attributes[:role_id]) if attributes[:role_id].present?

    # Track role changes
    old_role = @membership.role
    @membership.assign_attributes(attributes)

    if Memberships::LastAdminGuard.blocks?(@membership)
      load_members
      flash.now[:alert] = t('flash.memberships.last_active_admin', organisation: current_organisation.name)
      render :index, status: :unprocessable_content
      return
    end

    if @membership.save
      # Track role change if it happened
      if old_role&.id != @membership.role_id
        new_role = @membership.role

        # Track role removal from old role
        if old_role
          @membership.user.track_role_removal(
            old_role,
            project: nil, # Organisation-wide role
            removed_by: current_user
          )
        end

        # Track role assignment to new role
        if new_role
          @membership.user.track_role_assignment(
            new_role,
            project: nil, # Organisation-wide role
            assigned_by: current_user
          )
        end
      end

      warn_if_guest_ceiling_exceeded(@membership.user)
      destination = if @membership.user_id == current_user.id
                      @membership.active? ? organisation_memberships_path(current_organisation) : select_organisation_path
                    else
                      organisation_memberships_path(current_organisation, **list_params)
                    end
      redirect_to destination,
                  status: :see_other, notice: t('flash.memberships.updated')
    else
      load_members
      render :index, status: :unprocessable_content
    end
  end

  # No warn_if_guest_ceiling_exceeded call here (unlike #update): removing a
  # membership can only shrink a user's guest footprint, never create a new
  # Guest-Ceiling violation -- a hint here would never fire and would be
  # dead code, not a missing check.
  def destroy
    @membership = Membership.find(params[:id])
    authorize @membership

    service = RemoveMembershipService.new(
      membership: @membership,
      admin: current_user
    )

    if service.call
      target_user = @membership.user
      notice = "#{target_user.full_name} wurde aus der Organisation entfernt."

      notice += ' Der Benutzer hat keine weiteren Organisationen und sollte möglicherweise gelöscht werden.' if target_user.deletion_recommended?

      redirect_to organisation_memberships_path(current_organisation), notice: notice
    else
      redirect_to organisation_memberships_path(current_organisation),
                  alert: t('flash.memberships.remove_error', error: service.errors.join(', '))
    end
  end

  private

  def list_params
    params.slice(:q, :sort, :direction, :membership_id).permit!.to_h.symbolize_keys
  end

  def load_members
    @memberships = policy_scope(Membership).includes(:role, user: { avatar_attachment: :blob }).to_a
    @member_count = @memberships.size
    @invitations = policy_scope(Invitation).pending.order(sent_at: :desc)
    @roles = policy_scope(Role).order(:title).to_a if current_user.account_admin_in?(current_organisation)
    query = params[:q].to_s.strip.downcase
    # The shown email only (User::EmailDisplay): a hidden login address is neither matched nor sorted by.
    @memberships.select! { |member| [member.user.full_name, member.user.shown_email].any? { |value| value.to_s.downcase.include?(query) } } if query.present?
    @memberships.sort_by! do |member|
      case params[:sort]
      when 'role' then [helpers.membership_role_name(member.role).downcase, member.user.full_name.to_s.downcase, member.id]
      when 'since' then [member.created_at, member.id]
      else [helpers.viewer_display_name(member.user).downcase, member.user.shown_email.to_s, member.id]
      end
    end
    @memberships.reverse! if params[:direction] == 'desc'
  end

  def membership_params
    params.require(:membership).permit(:role_id, :active)
  end
end
