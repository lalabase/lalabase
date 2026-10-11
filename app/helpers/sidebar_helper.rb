# frozen_string_literal: true

module SidebarHelper
  # Determines the active sidebar tab based on controller and action.
  # Computed once and passed through to the sidebar components.
  #
  # @return [String] the active tab name or '' if none is active
  def current_sidebar_tab
    return '' unless current_project.present?

    case controller_name
    when 'projects' then action_name == 'edit' ? 'settings' : 'dashboard'
    when 'chats' then 'chats'
    when 'tickets' then 'tickets'
    when 'knowledge' then 'knowledge'
    when 'notes' then 'knowledge'
    when 'documents' then 'knowledge'
    when 'documentation' then 'documentation'
    when 'documentation_sets' then 'documentation'
    when 'time_sessions' then 'time_sessions'
    when 'meetings' then 'meetings'
    when 'project_permissions' then 'members'
    when 'smart_folders' then 'smart_folders'
    when 'dashboard_configurations' then 'dashboard'
    when 'activities' then 'activities'
    when 'ticket_attribute_definitions' then 'settings'
    else ''
    end
  end
end
