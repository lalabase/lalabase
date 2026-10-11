# frozen_string_literal: true

module Organisations
  class UserActivitiesController < Organisations::BaseController
    include Pagy::Backend

    before_action :authenticate_user!
    before_action :set_user
    before_action :authorize_view_activities!

    # GET /org/:organisation_id/user_activities?user_id=:user_id
    def index
      # Skip Pundit authorization and policy scoping for this action since we have custom authorization
      skip_authorization
      skip_policy_scope

      activities_scope = UserActivity.includes(:organisation, :trackable)
                                     .for_user(@user)
                                     .for_organisation(current_organisation)
                                     .recent

      # Filter options
      activities_scope = activities_scope.for_category(params[:category]) if params[:category].present?

      activities_scope = activities_scope.for_action(params[:action_type]) if params[:action_type].present?

      activities_scope = activities_scope.where(status: params[:status]) if params[:status].present?

      activities_scope = activities_scope.where('created_at >= ?', Date.parse(params[:date_from]).beginning_of_day) if params[:date_from].present?

      activities_scope = activities_scope.where('created_at <= ?', Date.parse(params[:date_to]).end_of_day) if params[:date_to].present?

      # Pagination with Pagy
      @pagy, @activities = pagy(activities_scope, items: 50)

      # User-specific statistics for this organisation
      @user_stats = {
        total_activities: @user.user_activities.for_organisation(current_organisation).count,
        last_login: @user.user_activities
                         .for_organisation(current_organisation)
                         .where(action: 'login')
                         .recent
                         .first&.created_at,
        failed_logins_24h: @user.user_activities
                                .for_organisation(current_organisation)
                                .where(action: 'login_failed')
                                .where('created_at >= ?', 24.hours.ago)
                                .count,
        total_logins: @user.user_activities
                           .for_organisation(current_organisation)
                           .where(action: 'login')
                           .count,
        security_events: @user.user_activities
                              .for_organisation(current_organisation)
                              .security_activities
                              .count
      }

      # Activity breakdown by category
      @category_breakdown = @user.user_activities
                                 .for_organisation(current_organisation)
                                 .group(:category)
                                 .count
                                 .sort_by { |_, count| -count }

      # Membership info for context
      @membership = current_organisation.memberships.find_by(user: @user)
    end

    private

    def set_user
      @user = User.find(params[:user_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to organisation_memberships_path(current_organisation),
                  alert: t('flash.user_activities.user_not_found')
    end

    def authorize_view_activities!
      # Check whether the current user is an admin of the organisation
      unless current_user.account_admin_in?(current_organisation)
        redirect_to organisation_memberships_path(current_organisation),
                    alert: t('flash.user_activities.no_view_permission')
      end

      # Check whether the requested user is a member of the organisation
      return if current_organisation.users.include?(@user)

      redirect_to organisation_memberships_path(current_organisation),
                  alert: t('flash.user_activities.not_member')
    end
  end
end
