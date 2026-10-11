# frozen_string_literal: true

class Dashboard::NotificationsComponent < ViewComponent::Base
  def initialize(project:, user:, limit: 5)
    @project = project
    @user = user
    @limit = limit
  end

  # Own notifications are always accessible
  def should_render?
    true
  end

  private

  attr_reader :project, :user, :limit

  # The inbox rule (Notification.inbox_unread: areas, active projects), narrowed to
  # this project, so the card never offers a row its inbox link cannot show.
  def unread_in_project
    Notification.inbox_unread(user, project.organisation).where(project: project)
  end

  def notifications
    @notifications ||= unread_in_project.includes(:actor, :notifiable)
                                        .order(created_at: :desc)
                                        .limit(limit)
  end

  def unread_count
    @unread_count ||= unread_in_project.count
  end

  def current_organisation
    project.organisation
  end
end
