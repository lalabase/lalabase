# frozen_string_literal: true

# ProjectController Concern
#
# This concern provides the basic functionality for all project-related controllers.
# It is used in controllers that operate within a project (e.g. Tickets, TimeSessions, Notes).
#
# Key functions:
# 1. Authentication of the user
# 2. Authorization of the project membership
# 3. Setting the project variables (@project and @current_project)
#
# Usage:
#   class TicketsController < ApplicationController
#     include ProjectController
#     ...
#   end
#
# The @current_project variable is especially important for navigation and the layout,
# since it drives the project navigation in the sidebar (application.html.erb renders
# 'common/sidebar_project_list', which builds the per-project nav via
# NeoSidebarProjectItemComponent).

module ProjectController
  extend ActiveSupport::Concern
  include AiFeatureGate

  included do
    before_action :set_project
    before_action :authorize_project_access!
  end

  private

  def set_project
    # Eager load organization for NeoProjectNavigationComponent permissions
    @project = Project.includes(:organisation).find(params[:project_id])
    @current_project = @project
    touch_project_last_accessed(@project)
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('flash.shared.project_not_found')
    redirect_to organisation_projects_path(@current_organisation) and return
  end

  # GDPR org-level AI opt-in guard: lives in AiFeatureGate since S3a T2 (the rule
  # is org-level; the project-less assistant controllers need it too). Included
  # here so every project controller keeps `ensure_ai_enabled` exactly as before.

  # Checks whether the user has access to the respective project area
  def authorize_project_access!
    # Early return if the project is not yet set or a redirect has occurred
    return if @project.nil? || performed?

    # Determine the area from the controller name
    area = determine_access_area

    # Debug logging for the permission check
    log_permission_check(area)

    # Determine the required action (read/write)
    action = determine_required_action

    # Perform the permission check with the Pundit policy
    can_access = policy(@project).area_access?(area, action)

    # If access is not allowed, redirect the user
    handle_access_denied(area) unless can_access
  end

  # Determines the access area based on the controller name
  def determine_access_area
    # Derive the area from the controller name
    area = controller_name.gsub('_controller', '').singularize.to_sym

    # Adapt the area name to ProjectPermission's expectations
    # Special handling for sub-resources and related controllers
    return :tickets if %i[ticket post post_reaction].include?(area)
    return :notes if area == :note
    return :meetings if area == :meeting
    return :chats if %i[chat chatpost].include?(area)
    return :documents if area == :document
    return :time_sessions if area == :time_session

    # If there is no special mapping, return the original area
    area
  end

  # Determines whether the current action requires read or write permissions.
  # create_summary (tickets + meetings AI summary) mutates the record and enqueues
  # a paid LLM job — it must fail closed at this concern layer too, not rest on the
  # single in-action Pundit `authorize :update?` line alone (review #235).
  def determine_required_action
    # run/accept/dismiss are the meeting ticket-suggestion writes (Slice 8): a run
    # enqueues a paid LLM job, accept creates a real ticket — both must fail closed
    # at this concern layer, exactly like create_summary/detect_participants.
    # regenerate (chatposts) persists a style nudge and enqueues a paid LLM job —
    # same fail-closed rule (Actors C1 review).
    # move_preflight/move: moving a meeting into another project needs write
    # access to the project it leaves (its dialog too, it offers only that).
    write_actions = %w[new create edit update destroy create_summary detect_participants
                       run accept dismiss regenerate move_preflight move]
    write_actions.include?(action_name) ? :write : :read
  end

  # This method was removed and integrated into authorize_project_access!
  # The permission check now happens directly via the ProjectPolicy

  # Logs information about the permission check
  def log_permission_check(_area)
    # Intentionally empty - debug logging removed for production
  end

  # Logs detailed permission information and redirects the user
  def handle_access_denied(area)
    log_detailed_permissions(area)
    flash[:alert] = t('flash.shared.not_authorized')

    # Here we check whether the action has already been performed
    # This is important for controllers that have their own permission check
    # and may have already performed a redirect
    return if performed?

    redirect_to organisation_project_path(@current_organisation, @project)
  end

  # Throttled touch of last_accessed_at on project_permission (max 1x/hour per user+project)
  def touch_project_last_accessed(project)
    return unless user_signed_in?

    permission = current_user.project_permissions.find_by(project_id: project.id)
    return unless permission
    return if permission.last_accessed_at&.> 1.hour.ago

    permission.update_column(:last_accessed_at, Time.current)
  end

  # Logs detailed information about project and role permissions
  def log_detailed_permissions(_area)
    # Intentionally empty - debug logging removed for production
  end
end
