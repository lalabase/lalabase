# frozen_string_literal: true

class Dashboard::SmartFolderTicketsComponent < ViewComponent::Base
  include TicketsHelper

  def initialize(project:, user:, smart_folder_id:, limit: nil)
    @project = project
    @user = user
    @smart_folder_id = smart_folder_id
    @limit = limit
  end

  def before_render
    @smart_folder = SmartFolderPolicy::Scope.new(user, project.smart_folders).resolve
                                            .where(target_object_type: %w[Ticket All]).find_by(id: smart_folder_id)
  end

  def should_render?
    return false unless Current.project_policy(user, project).area_access?(:tickets, :read)

    true
  end

  private

  attr_reader :project, :user, :smart_folder_id, :smart_folder

  def folder_available?
    smart_folder.present? && smart_folder.accessible_by?(user)
  end

  def results
    return [] unless folder_available?

    @results ||= begin
      scope = TicketPolicy::Scope.new(user, project.tickets).resolve
      SmartFolderQueryBuilder.new(smart_folder, user).filter_relation(scope)
                             .reorder(sort_column => smart_folder.effective_sort_direction, id: :desc).limit(item_limit).includes(:assignees).to_a
    end
  end

  def sort_column
    smart_folder.effective_sort_column.presence_in(%w[title number created_at updated_at]) || 'updated_at'
  end

  def item_limit
    Dashboards::LayoutEngine.effective_item_limit('key' => 'smart_folder_tickets', 'limit' => @limit)
  end

  def folder_name
    smart_folder&.name || t('dashboard.smart_folder_tickets.unavailable')
  end

  def unread_notifications_per_ticket
    @unread_notifications_per_ticket ||= user.notifications
                                             .channel_in_app
                                             .unread
                                             .where(notifiable_type: 'Ticket', project_id: project.id)
                                             .group(:notifiable_id)
                                             .count
  end

  def ticket_highlight_classes(ticket)
    return 'bg-cream-50' unless ticket.respond_to?(:has_system_function?)

    is_closed_or_done = ticket.has_system_function?(SystemFunctions::Registry::IS_COMPLETED) ||
                        ticket.has_system_function?(SystemFunctions::Registry::IS_CLOSED)
    return HIGH_PRIORITY_HIGHLIGHT if !is_closed_or_done && ticket.has_system_function?(SystemFunctions::Registry::HIGH_PRIORITY)

    'bg-cream-50'
  end

  def current_organisation
    project.organisation
  end
end
