# frozen_string_literal: true

class Dashboard::TimeTrackingComponent < ViewComponent::Base
  def initialize(project:, user:)
    @project = project
    @user = user
  end

  def should_render?
    Current.project_policy(user, project).area_access?(:time_sessions, :read)
  end

  private

  attr_reader :project, :user

  def unbilled_stats
    @unbilled_stats ||= begin
      permitted_sessions = policy_scope(project.time_sessions.unbilled)
      open_tickets_count = permitted_sessions.joins(:ticket).distinct.count('tickets.id')

      {
        total_duration: permitted_sessions.sum(:duration),
        open_tickets_count: open_tickets_count,
        session_count: permitted_sessions.count
      }
    end
  end

  def policy_scope(scope)
    TimeSessionPolicy::Scope.new(user, scope).resolve
  end

  def formatted_duration
    (unbilled_stats[:total_duration] / 60.0).round(1)
  end

  def recent_sessions
    @recent_sessions ||= begin
      permitted = policy_scope(project.time_sessions)
      permitted.includes(:ticket, :creator)
               .order(created_at: :desc)
               .limit(5)
    end
  end

  def current_organisation
    project.organisation
  end
end
