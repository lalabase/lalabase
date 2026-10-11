# frozen_string_literal: true

# =============================================================================
# Admin Users Controller
# =============================================================================
# Handles administrative operations for user management in the admin backend.
#
# Features:
# - List all users with filtering by active/inactive status
# - Create new users with associated organizations
# - Toggle user active/inactive status
#
# Security:
# - Protected by admin authentication (Admin::ApplicationController)
# - Uses strong parameters for user input validation
# - Atomic transactions for data consistency
#
# Multi-tenancy:
# - Works with acts_as_tenant system for organization isolation
# - Handles tenant context switching during organization creation
# =============================================================================

module Admin
  class UsersController < Admin::ApplicationController
    # ==========================================================================
    # GET /admin/users
    # ==========================================================================
    # Displays a paginated list of all users with optional status filtering.
    #
    # Query Parameters:
    # - status: 'active' | 'inactive' | nil (all users)
    #
    # View Variables:
    # - @users: Filtered and ordered collection of users
    # ==========================================================================
    def index
      # Use Admin::User model which operates without tenant restrictions.
      # The Lalabase system account (onboarding seed actor) is not a real user
      # and stays out of the admin listing entirely.
      @users = Admin::User.without_system

      # Apply status filter based on query parameter
      # This allows admins to quickly view only active or inactive users
      case params[:status]
      when 'active'
        @users = @users.active    # Uses Admin::User.active scope
      when 'inactive'
        @users = @users.inactive  # Uses Admin::User.inactive scope
      end

      # Order by creation date for consistent display
      @users = @users.ordered_by_creation
    end

    # ==========================================================================
    # GET /admin/users/deleted
    # ==========================================================================
    # Displays a list of all deleted users with their deletion information.
    # Shows anonymized user data and deletion audit trail.
    #
    # View Variables:
    # - @deleted_users: Collection of deleted users with deletion info
    # - @deletion_stats: Statistics about deletions
    # ==========================================================================
    def deleted
      # Get deleted users using unscoped to bypass the deleted_at filter
      @deleted_users = Admin::User.unscoped
                                  .where.not(deleted_at: nil)
                                  .order(deleted_at: :desc)

      # Get deletion audit records for additional info
      user_ids = @deleted_users.pluck(:id)
      @deletion_records = UserDeletion.where(deleted_user_id: user_ids)
                                      .includes(:deleter)
                                      .order(deleted_at: :desc)

      # Create a map for easy lookup
      @deletion_map = @deletion_records.index_by(&:deleted_user_id)

      # Calculate deletion statistics
      @deletion_stats = {
        total_deleted: @deleted_users.count,
        deleted_today: @deleted_users.where('deleted_at >= ?', Date.current).count,
        deleted_this_week: @deleted_users.where('deleted_at >= ?', 1.week.ago).count,
        deleted_this_month: @deleted_users.where('deleted_at >= ?', 1.month.ago).count,
        backend_deletions: @deletion_records.where(source: 'backend').count,
        selfservice_deletions: @deletion_records.where(source: 'selfservice').count
      }
    end

    # ==========================================================================
    # GET /admin/users/new
    # ==========================================================================
    # Displays the form for creating a new user with an associated organization.
    #
    # View Variables:
    # - @user: New User instance for form binding
    # - @organisation: New Organisation instance for form binding
    # ==========================================================================
    def new
      # Uses Admin:: models to bypass acts_as_tenant restrictions
      # SECURITY: This route is only available in the admin backend
      @user = Admin::User.new
      @organisation = Admin::Organisation.new
      @organisations = Admin::Organisation.ordered_by_name
    end

    # ==========================================================================
    # POST /admin/users
    # ==========================================================================
    # Creates a new user and associated organization in a single atomic transaction.
    #
    # Process Flow:
    # 1. Create organization first (required for tenant context)
    # 2. Set tenant context for role operations (acts_as_tenant requirement)
    # 3. Create admin role for the new organization
    # 4. Generate temporary password for the user
    # 5. Create user with specified active status
    # 6. Create membership linking user to organization with admin role
    #
    # Error Handling:
    # - Uses database transaction for atomicity (all-or-nothing)
    # - Catches validation errors and database errors separately
    # - Provides user-friendly error messages
    #
    # Security:
    # - Password is randomly generated and displayed once to admin
    # - User should change password on first login
    # ==========================================================================
    def create
      # ==========================================================================
      # CRITICAL ADMIN-ONLY AREA
      # ==========================================================================
      # WARNING: This code bypasses all acts_as_tenant security mechanisms!
      # Must NEVER be used in frontend controllers!

      temporary_password = SecureRandom.alphanumeric(12)
      @user = Admin::User.new(user_params)

      if params[:organisation_mode] == 'existing'
        create_user_with_existing_org(temporary_password)
      else
        create_user_with_new_org(temporary_password)
      end
    end

    # ==========================================================================
    # GET /admin/users/:id
    # ==========================================================================
    # Displays detailed information about a specific user including:
    # - Basic user information (name, email, status, creation date)
    # - Organization memberships and roles
    # - Project permissions across all organizations
    # - Activity summary and statistics
    #
    # View Variables:
    # - @user: User instance with preloaded associations
    # - @memberships: User's organization memberships with roles
    # - @project_permissions: User's specific project permissions
    # - @user_stats: Calculated statistics for the user
    # ==========================================================================
    def show
      # Use Admin::User model which operates without tenant restrictions
      @user = Admin::User.find(params[:id])

      # Load memberships with details using Admin models
      @memberships = @user.memberships_with_details.to_a

      # Load project permissions with details using Admin models
      @project_permissions = @user.project_permissions_with_details.to_a

      # Calculate user statistics using Admin model methods
      @user_stats = {
        total_organisations: @user.total_organisations_count,
        active_memberships: @user.active_memberships_count,
        total_projects_with_access: @user.total_projects_with_access_count,
        account_admin_orgs: @user.account_admin_organisations_count,
        last_login: nil, # Could be implemented if we track login timestamps
        member_since: @user.created_at
      }

      # Load User Activities for the activity history section
      # We need to use the regular User model for activities since UserActivity belongs to User.
      # Use find_with_deleted: Admin::User (line above) has no SoftDeletable default scope and
      # thus resolves soft-deleted users, so the admin index/deleted list links here for them.
      # Plain ::User.find would hit `WHERE deleted_at IS NULL` and raise RecordNotFound (blank 404).
      regular_user = ::User.find_with_deleted(params[:id])

      # Recent activities for the timeline
      @recent_activities = regular_user.user_activities
                                       .includes(:organisation)
                                       .recent
                                       .limit(10)

      # Activity statistics
      @last_seen = regular_user.last_seen_at
      @last_login = regular_user.last_login_activity
      @login_count_30d = regular_user.login_count(since: 30.days.ago)
      @failed_logins_24h = regular_user.failed_login_count(since: 24.hours.ago)
      @total_activities = regular_user.user_activities.count

      # Notification preferences
      # Ticket notifications: nil/missing = On (default), only explicit false = Off
      ticket_prefs = regular_user.preferences['ticket_notifications'] || {}
      @ticket_notification_settings = {
        on_status_change: ticket_prefs['on_status_change'] != false,
        on_priority_change: ticket_prefs['on_priority_change'] != false,
        on_comment: ticket_prefs['on_comment'] != false,
        auto_follow_created: ticket_prefs['auto_follow_created'] != false
      }

      # Event preferences: only org level (scope_type: nil), no project/item level
      @notification_preferences_by_org = NotificationPreference
                                         .where(user_id: params[:id])
                                         .where.not(organisation_id: nil)
                                         .where(scope_type: nil)
                                         .includes(:organisation)
                                         .group_by(&:organisation)
    end

    # ==========================================================================
    # PATCH /admin/users/:id/toggle_active
    # ==========================================================================
    # Toggles the active status of a user between active and inactive.
    #
    # This is a toggle operation:
    # - Active users become inactive
    # - Inactive users become active
    #
    # Security:
    # - Only accessible by admin users
    # - Includes CSRF protection via button_to in view
    # - Confirmation dialog prevents accidental changes
    #
    # Logging:
    # - Status changes are logged for audit trail
    # - Errors are logged for debugging
    #
    # UI Feedback:
    # - Success/error messages displayed to admin
    # - Redirects back to user list for immediate visual confirmation
    # ==========================================================================
    def toggle_active
      # Use Admin::User model which operates without tenant restrictions
      @user = Admin::User.find(params[:id])
      old_status = @user.active

      # Toggle the active status (true -> false, false -> true)
      @user.update!(active: !@user.active)

      # Determine appropriate status message for user feedback
      status = @user.active? ? t('generic.enabled', default: 'aktiviert') : t('generic.disabled', default: 'deaktiviert')

      # Log the change for audit trail
      Rails.logger.info "User #{@user.email} status changed from #{old_status} to #{@user.active}"

      # Redirect with success message
      redirect_to admin_users_path, notice: t('flash.admin.users.toggled', email: @user.email, status: status)
    rescue ActiveRecord::RecordInvalid => e
      # Log error for debugging
      Rails.logger.error "Failed to toggle user status: #{e.message}"

      # Redirect with error message
      redirect_to admin_users_path, alert: t('flash.admin.users.toggle_error', error: e.message)
    end

    # ==========================================================================
    # DELETE /admin/users/:id
    # ==========================================================================
    # Soft deletes a user account with full anonymization and audit trail.
    # Only accessible by authenticated beusers.
    #
    # Process:
    # 1. Validates that current beuser has permission
    # 2. Executes soft delete with anonymization via DeleteAccountService
    # 3. Creates audit log entry
    # 4. Provides user feedback
    #
    # Security:
    # - Only accessible by authenticated beusers
    # - Validates permission through DeleteAccountService
    # - Uses database transaction for atomicity
    # ==========================================================================
    def destroy
      @user = Admin::User.find(params[:id])
      original_email = @user.email

      # Binding guard: the modal's disabled button is a UX affordance only. Without this
      # check a hand-crafted DELETE (or a broken client) would wipe the account outright.
      # Comparison rule must stay in sync with admin_user_delete_modal_controller.js.
      unless confirmation_matches?(params[:email_confirmation], original_email)
        redirect_to admin_user_path(@user), alert: t('flash.admin.users.email_confirmation_mismatch')
        return
      end

      # For admin interface, current_user is already a Beuser
      service = DeleteAccountService.new(
        target_user: @user,
        requester: current_user,
        source: 'backend',
        reason: params[:reason]
      )

      if service.call
        redirect_to admin_users_path, notice: t('flash.admin.users.deleted', email: original_email)
      else
        redirect_to admin_users_path, alert: t('flash.shared.delete_error', error: service.errors.join(', '))
      end
    end

    # ==========================================================================
    # DELETE /admin/users/:id/memberships/:membership_id
    # ==========================================================================
    # Removes a user from an organization by deleting their membership.
    # Only accessible by backend admins (beusers).
    #
    # Process:
    # 1. Finds the membership to remove
    # 2. Uses RemoveMembershipService to handle removal properly
    # 3. Sets deletion_recommended flag if user has no other memberships
    # 4. Provides feedback about the action
    # ==========================================================================
    def destroy_membership
      @user = Admin::User.find(params[:id])
      membership = @user.memberships.find(params[:membership_id])

      # For backend removal, we need an admin user from the organization
      # We'll use the first admin we can find, or create a temporary context
      admin_user = membership.organisation.memberships
                             .joins(:role)
                             .where(roles: { title: 'account_admin' })
                             .first&.user

      # If no admin exists, we can directly destroy as backend operation
      if admin_user
        service = RemoveMembershipService.new(
          membership: membership,
          admin: admin_user
        )

        if service.call
          notice = t('flash.admin.users.membership_removed', email: @user.email, org_name: membership.organisation.name)
          notice += t('flash.admin.users.deletion_recommended') if @user.deletion_recommended?
          redirect_to admin_user_path(@user), notice: notice
        else
          redirect_to admin_user_path(@user), alert: t('flash.admin.users.membership_remove_service_error', error: service.errors.join(', '))
        end
      else
        # Direct backend removal when no admin exists
        membership.destroy!

        # Check if user should be flagged for deletion
        @user.mark_for_deletion_review! if @user.should_be_recommended_for_deletion?

        notice = t('flash.admin.users.membership_removed_backend', email: @user.email, org_name: membership.organisation.name)
        notice += t('flash.admin.users.deletion_recommended') if @user.deletion_recommended?

        redirect_to admin_user_path(@user), notice: notice
      end
    rescue StandardError => e
      redirect_to admin_user_path(@user), alert: t('flash.admin.users.membership_remove_error', error: e.message)
    end

    private

    # ==========================================================================
    # Deletion Confirmation
    # ==========================================================================
    # The admin has to retype the target's email address before an account is
    # destroyed. Whitespace and casing are forgiving on purpose: the point is to
    # confirm intent, not to test typing accuracy. A blank input never matches.
    # ==========================================================================
    def confirmation_matches?(input, email)
      normalized_input = input.to_s.strip.downcase
      normalized_input.present? && normalized_input == email.to_s.strip.downcase
    end

    # ==========================================================================
    # Strong Parameters for User Creation/Updates
    # ==========================================================================
    # Defines which user parameters are permitted from form submissions.
    #
    # Permitted Parameters:
    # - first_name: User's first name (optional)
    # - last_name: User's last name (optional)
    # - email: User's email address (required, must be unique)
    # - active: User's active status (boolean, defaults to true)
    # ==========================================================================
    def user_params
      params.require(:user).permit(:first_name, :last_name, :email, :active)
    end

    def organisation_params
      params.require(:organisation).permit(:name, :subdomain, :domain)
    end

    def prepare_new_form
      @organisation ||= Admin::Organisation.new
      @organisations = Admin::Organisation.ordered_by_name
    end

    # Creates user + new organisation + account_admin membership via the shared
    # Actors::CreateUserWithOrganisation (same OrganisationBootstrap as the web path in
    # OrganisationsController#create). current_user here is a Beuser, so it is NOT passed
    # as the actor's audit user (see decision D-D / the actor's docs).
    def create_user_with_new_org(temporary_password)
      @organisation = Admin::Organisation.new(organisation_params)
      @user.password = temporary_password
      @user.password_confirmation = temporary_password

      result = Actors::CreateUserWithOrganisation.call(
        user: @user,
        organisation: @organisation,
        current_user: nil
      )

      if result.success?
        redirect_to admin_users_path,
                    notice: t('flash.admin.users.created_with_new_org', email: @user.email, org_name: @organisation.name, password: temporary_password)
      else
        render_create_failure(t('flash.admin.users.create_error', error: result.errors.join(', ')))
      end
    end

    # Creates user + membership in an existing organisation with a chosen role. Stays in
    # the controller: no organisation bootstrap, so it does not fit the shared actor.
    def create_user_with_existing_org(temporary_password)
      @organisation = Admin::Organisation.find(params[:existing_organisation_id])
      role = @organisation.roles.find(params[:role_id])

      ActiveRecord::Base.transaction do
        save_user_with_password(temporary_password)
        @user.memberships.create!(organisation: @organisation, role: role, active: true)
      end

      redirect_to admin_users_path,
                  notice: t('flash.admin.users.created_with_existing_org', email: @user.email, org_name: @organisation.name, role: role.title, password: temporary_password)
    rescue ActiveRecord::RecordInvalid => e
      render_create_failure(t('flash.admin.users.create_error', error: e.record.errors.full_messages.join(', ')))
    rescue StandardError => e
      render_create_failure(t('flash.shared.unexpected_error', error: e.message))
    end

    def save_user_with_password(temporary_password)
      @user.password = temporary_password
      @user.password_confirmation = temporary_password
      @user.save!
    end

    def render_create_failure(message)
      flash.now[:alert] = message
      prepare_new_form
      render :new, status: :unprocessable_entity
    end
  end
end
