# frozen_string_literal: true

class NeoProjectNavigationComponent < ViewComponent::Base
  def initialize(project:, current_tab: nil)
    @project = project
    @current_tab_override = current_tab
    @area_access_cache = {}
  end

  def before_render
    @current_tab = @current_tab_override || detect_current_tab
    setup_permissions
  end

  private

  def detect_current_tab
    case helpers.controller_name
    when 'projects' then helpers.action_name == 'edit' ? 'settings' : 'dashboard'
    when 'tickets' then 'tasks'
    when 'knowledge' then 'knowledge'
    when 'notes' then 'knowledge'
    when 'documents' then 'knowledge'
    when 'documentation' then 'documentation'
    when 'documentation_sets' then 'documentation'
    when 'meetings' then 'meetings'
    when 'project_permissions' then 'members'
    when 'smart_folders' then 'smart_folders'
    when 'activities' then 'activities'
    else ''
    end
  end

  def setup_permissions
    project_policy = helpers.policy(@project)

    @can_change_project = helpers.current_user.has_permission_in_organisation?(@project.organisation, 'projects', 'change_project_properties')
    @has_project_access = project_policy.show?
    @is_admin = helpers.current_user.account_admin_in?(@project.organisation)
    @can_view_members = project_policy.area_access?(:members, :read) || project_policy.area_access?(:members, :write)
    @can_view_activities = project_policy.view_activities?

    # Optimized: Single call per area, check both read and write at once.
    @can_access_tickets = has_area_access?(project_policy, :tickets)
    @can_access_notes = has_area_access?(project_policy, :notes)
    @can_access_documents = has_area_access?(project_policy, :documents)
    @can_access_knowledge = @can_access_notes || @can_access_documents
    @can_access_documentation = has_area_access?(project_policy, :documentation)
    @can_access_meetings = has_area_access?(project_policy, :meetings)
  end

  def has_area_access?(policy, area)
    # Cache the result to avoid duplicate calls within same render
    @area_access_cache[area] ||= policy.area_access?(area, :read) || policy.area_access?(area, :write)
  end

  def navigation_params
    # Don't include items parameter in navigation links - let each controller handle it from session
    # This prevents hardcoding values in URLs that override session preferences
    # The receiving controller will use the session value if no items param is present
    {}
  end

  def tickets_params
    # Add page=1 for tickets when coming from another controller
    params = navigation_params.dup
    if helpers.controller_name != 'tickets'
      # If we're not on the tickets page, make sure we land on page 1
      params[:page] = 1
    end
    params
  end

  def tab_active?(tab_name)
    @current_tab == tab_name
  end

  def tab_classes(active)
    base_classes = 'pt-0 pb-4 text-sm font-black uppercase tracking-tight transition-all whitespace-nowrap'
    if active
      "#{base_classes} text-cream-900"
    else
      "#{base_classes} text-gray-400 hover:text-gray-700"
    end
  end
end
