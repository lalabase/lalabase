# frozen_string_literal: true

require 'csv'
require 'ostruct'

module Admin
  class UserActivitiesController < Admin::ApplicationController
    before_action :set_user, only: [:user_activities]

    # GET /admin/user_activities
    # Shows all user activities system-wide
    def index
      @activities = UserActivity.includes(:user, :organisation)
                                .recent
                                .limit(100)

      # Filter options
      if params[:user_id].present?
        @activities = @activities.for_user(params[:user_id])
        # Admin::User (no SoftDeletable scope) resolves soft-deleted users too, so the
        # filter still works when linked from the admin UI. Explicit namespace, not the
        # accidental `User` resolution, and consistent with set_user below.
        @filtered_user = Admin::User.find(params[:user_id])
      end

      @activities = @activities.for_category(params[:category]) if params[:category].present?

      @activities = @activities.for_action(params[:action_type]) if params[:action_type].present?

      @activities = @activities.where(status: params[:status]) if params[:status].present?

      @activities = @activities.where('created_at >= ?', Date.parse(params[:date_from]).beginning_of_day) if params[:date_from].present?

      @activities = @activities.where('created_at <= ?', Date.parse(params[:date_to]).end_of_day) if params[:date_to].present?

      # Statistics for the dashboard
      @stats = {
        total_today: UserActivity.today.count,
        failed_logins_today: UserActivity.today.failed.where(action: 'login_failed').count,
        new_registrations_today: UserActivity.today.where(action: 'registered').count,
        active_users_today: UserActivity.today.select(:user_id).distinct.count
      }

      # Top users by activity
      # Use a direct SQL query instead of joins because of Admin namespace conflicts
      @top_users = UserActivity.where('created_at >= ?', 7.days.ago)
                               .group(:user_id)
                               .order(Arel.sql('COUNT(*) DESC'))
                               .limit(5)
                               .pluck(:user_id, Arel.sql('COUNT(*) as count'))
                               .map do |user_id, count|
                                 user = ::User.find_by(id: user_id)
                                 next unless user

                                 OpenStruct.new(
                                   id: user.id,
                                   email: user.email,
                                   activities_count: count
                                 )
                               end.compact
    end

    # GET /admin/users/:user_id/activities
    # Shows activities for a specific user
    def user_activities
      # We need to use the regular User model for activities since UserActivity belongs to User.
      # find_with_deleted mirrors set_user's Admin::User lookup so soft-deleted users
      # (linked from the detail page's "show all activities") render instead of 404ing.
      regular_user = ::User.find_with_deleted(params[:user_id])

      @activities = regular_user.user_activities
                                .includes(:organisation)
                                .recent
                                .limit(100)

      # User-specific statistics
      @user_stats = {
        total_activities: regular_user.user_activities.count,
        last_login: regular_user.last_login_at,
        last_ip: regular_user.last_login_ip,
        failed_logins_24h: regular_user.failed_login_count,
        total_logins: regular_user.login_count,
        security_events: regular_user.security_activities.count
      }

      # Activity breakdown by category
      @category_breakdown = regular_user.user_activities
                                        .group(:category)
                                        .count
                                        .sort_by { |_, count| -count }

      # Recent sessions
      @recent_sessions = regular_user.user_activities
                                     .where(action: %w[login logout])
                                     .recent
                                     .limit(10)
    end

    # GET /admin/user_activities/:id
    # Shows details of a specific activity
    def show
      @activity = UserActivity.find(params[:id])
      @user = @activity.user

      # Related activities (same session)
      if @activity.session_id.present?
        @session_activities = UserActivity.where(session_id: @activity.session_id)
                                          .where.not(id: @activity.id)
                                          .recent
      end

      # Previous and next activity of the user
      @previous_activity = @user.user_activities
                                .where('created_at < ?', @activity.created_at)
                                .recent
                                .first

      @next_activity = @user.user_activities
                            .where('created_at > ?', @activity.created_at)
                            .order(created_at: :asc)
                            .first
    end

    # GET /admin/user_activities/security
    # Security-focused view
    def security
      @security_events = UserActivity.where(
        action: %w[login_failed account_locked suspicious_activity
                   api_token_created api_token_deleted]
      ).includes(:user, :organisation)
                                     .recent
                                     .limit(100)

      # Users with many failed logins
      # Use a direct SQL query instead of joins because of Admin namespace conflicts
      @suspicious_users = UserActivity.where(action: 'login_failed')
                                      .where('created_at >= ?', 24.hours.ago)
                                      .group(:user_id)
                                      .having('COUNT(*) >= ?', 3)
                                      .pluck(:user_id, Arel.sql('COUNT(*) as count'))
                                      .map do |user_id, count|
                                        user = ::User.find_by(id: user_id)
                                        next unless user

                                        OpenStruct.new(
                                          id: user.id,
                                          email: user.email,
                                          failed_attempts: count
                                        )
                                      end.compact

      # IPs with many failed logins
      @suspicious_ips = UserActivity.where(action: 'login_failed')
                                    .where('created_at >= ?', 24.hours.ago)
                                    .where.not(ip_address: nil)
                                    .group(:ip_address)
                                    .having('COUNT(*) >= ?', 5)
                                    .count
                                    .sort_by { |_, count| -count }
    end

    # POST /admin/user_activities/export
    # Export activities as CSV
    def export
      activities = UserActivity.includes(:user, :organisation)

      # Apply filters
      activities = activities.for_user(params[:user_id]) if params[:user_id].present?
      activities = activities.for_category(params[:category]) if params[:category].present?
      activities = activities.where('created_at >= ?', Date.parse(params[:date_from])) if params[:date_from].present?
      activities = activities.where('created_at <= ?', Date.parse(params[:date_to])) if params[:date_to].present?

      respond_to do |format|
        format.csv do
          headers['Content-Disposition'] = "attachment; filename=\"user_activities_#{Date.current}.csv\""
          headers['Content-Type'] = 'text/csv'

          csv_data = CSV.generate(headers: true) do |csv|
            csv << ['ID', 'User', 'Action', 'Category', 'Status', 'IP Address',
                    'Organisation', 'Created At', 'Failure Reason']

            activities.find_each do |activity|
              row = [
                activity.id,
                activity.user.email,
                activity.action,
                activity.category,
                activity.status,
                activity.ip_address,
                activity.organisation&.name,
                activity.created_at.iso8601,
                activity.failure_reason
              ]
              csv << Lalabase::CsvSafe.row(row)
            end
          end

          send_data csv_data
        end
      end
    end

    private

    def set_user
      # Use Admin::User for the @user variable to maintain consistency with admin views
      @user = Admin::User.find(params[:user_id])
    end
  end
end
