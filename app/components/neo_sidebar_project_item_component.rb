# frozen_string_literal: true

# Renders ONE project in the sidebar: a prominent, clickable project name
# (= link to the dashboard) plus the indented child menu items. Multiple
# projects can be expanded/collapsed independently — the expand/collapse mechanism
# lives in sidebar_project_accordion_controller.js.
#
# Visibility model (DELIBERATELY chosen this way, please read before changes):
#   * ALL reachable items are ALWAYS rendered (canonical order).
#     "extra" items (neither pinned nor active) are, when collapsed, hidden only via CSS
#     (class "hidden") — NOT omitted. As a result the
#     order does not change on expand; nothing "jumps".
#   * Which items are initially visible does NOT depend on whether the project
#     is currently open ("current"). This is intentional: so that a project does
#     not automatically expand ("explode") when you navigate into it via a pinned
#     item. The expand state is solely the user's decision
#     (see controller / localStorage).
class NeoSidebarProjectItemComponent < ViewComponent::Base
  # Included, not reached through `helpers`: these two build strings and touch
  # no view context, and `helpers` is only there during a render - a unit test
  # that asks the component for its classes would get NoMethodError instead of
  # an answer.
  include SidebarNavHelper

  # The child menu items look like every other sidebar row, and since 07.09.2026
  # they SAY so instead of repeating it: SidebarNavHelper is the one owner (see
  # app/assets/stylesheets/components/sidebar_nav.css). Four constants used to
  # live here saying the same thing as four other places.

  # Primary items: reachable on EVERY project (even non-open ones),
  # so that you can jump directly into any project from anywhere. [tab, icon, i18n, path]
  NAV_ITEMS = [
    { tab: 'dashboard',     icon: 'bi-house',         i18n: 'navigation.dashboard', path: :project_dashboard_path },
    { tab: 'tickets',       icon: 'bi-list-task',     i18n: 'navigation.tasks',     path: :tickets_path },
    { tab: 'knowledge',     icon: 'bi-lightbulb',     i18n: 'navigation.knowledge', path: :knowledge_path },
    { tab: 'documentation', icon: 'bi-book',          i18n: 'navigation.documentation', path: :documentation_path },
    { tab: 'meetings',      icon: 'bi-chat-quote',    i18n: 'navigation.meetings', path: :meetings_path }
  ].freeze

  # Secondary items: only meaningful and reachable for the currently open
  # project (their permissions are context-dependent). [tab, icon, i18n, path, perm]
  MORE_ITEMS = [
    { tab: 'members',    icon: 'bi-people',   i18n: 'navigation.team',       path: :members_path,    perm: :can_members? },
    { tab: 'settings',   icon: 'bi-gear',     i18n: 'navigation.settings',   path: :settings_path,   perm: :can_settings? },
    { tab: 'activities', icon: 'bi-activity', i18n: 'navigation.activities', path: :activities_path, perm: :can_activities? }
  ].freeze

  # @param project [Project] the project
  # @param current_project [Project, nil] the currently open project
  # @param current_tab [String] the active tab (from SidebarHelper#current_sidebar_tab)
  # @param pinned_sections [Array<String>] pinned section tabs of this project
  # @param project_pinned [Boolean] whether the project itself is pinned
  def initialize(project:, current_project: nil, current_tab: '', pinned_sections: [], project_pinned: false)
    @project = project
    @current_project = current_project
    @current_tab = current_tab
    @raw_pinned_sections = pinned_sections
    @project_pinned = project_pinned
  end

  def current?
    @project.id == @current_project&.id
  end

  def project_pinned?
    @project_pinned
  end

  # Primary menu items of the project in canonical order. ALWAYS rendered
  # in full; "extra" (not pinned/active) are, when collapsed, hidden via
  # CSS (see the class comment above). The administrative items
  # are NOT here, but separately behind "More" (see more_items).
  def render_items
    accessible_nav_items
  end

  # Visible even when collapsed: pinned sections + (only on the current project)
  # the active tab. Everything else is "extra" and sits behind the chevron.
  def always_visible_tabs
    tabs = pinned_sections.dup
    tabs << @current_tab if current? && @current_tab.present? && nav_item_for(@current_tab)
    tabs.uniq
  end

  # "extra" = only visible behind the expand chevron.
  def extra?(item)
    !always_visible_tabs.include?(item[:tab])
  end

  def has_extras?
    render_items.any? { |i| extra?(i) } || has_more_items?
  end

  # Administrative items (team/settings/activities) behind "More".
  # Current-INDEPENDENT, so that they are consistently available on EVERY
  # (expanded) project. Previously they only appeared AFTER the project became the
  # current one — which felt as if they appeared out of nowhere.
  def more_items
    accessible_more_items
  end

  def has_more_items?
    more_items.any?
  end

  # Pinned sections in NAV_ITEMS order. Access is checked current-INDEPENDENTLY,
  # so that a pinned GPT/tickets also appears on a non-open project.
  def pinned_sections
    @pinned_sections ||= NAV_ITEMS.map { |i| i[:tab] }
                                  .select { |tab| @raw_pinned_sections.include?(tab) && tab_accessible?(tab) }
  end

  def section_pinned?(tab)
    pinned_sections.include?(tab)
  end

  def nav_item_for(tab)
    NAV_ITEMS.find { |i| i[:tab] == tab }
  end

  # Is a section pinnable? (whitelist tickets/knowledge/time_sessions/chats)
  def pinnable_section?(tab)
    User::SidebarPins::PINNABLE_SECTIONS.include?(tab)
  end

  def sidebar_pins_path
    helpers.organisation_sidebar_pins_path(organisation_id: @project.organisation_id)
  end

  # Renders a child menu item row (icon + text) plus a pin toggle for pinnable
  # sections.
  # @param extra [Boolean] whether the item is only visible behind the project chevron
  # @param collapsed [Boolean] whether currently collapsed (extra items then hidden)
  # @param more_item [Boolean] administrative item behind "More": initially hidden
  #   (data-more-item), revealed via a one-way reveal — NOT data-extra,
  #   so that the project chevron does not toggle it back against the reveal.
  def render_nav_item(item, extra: false, collapsed: false, more_item: false)
    tab = item[:tab]
    link = helpers.link_to(nav_item_path(item),
                           class: "flex-1 flex items-center gap-2 text-sm px-2 py-1.5 rounded transition-colors #{link_classes(tab)}") do
      helpers.safe_join([
                          helpers.content_tag(:i, '', class: "bi #{item[:icon]} #{icon_classes(tab)}"),
                          helpers.content_tag(:span, t(item[:i18n]))
                        ])
    end

    pin = pinnable_section?(tab) ? pin_toggle(group: 'sec', section: tab) : ''.html_safe

    # data-extra + "hidden": controlled by the project chevron.
    # data-more-item + "hidden": controlled by the "More" reveal (one-time).
    li_class = 'group/sec flex items-center'
    li_class += ' hidden' if (extra && collapsed) || more_item
    li_data = {}
    li_data[:extra] = '' if extra
    li_data[:'more-item'] = '' if more_item

    helpers.content_tag(:li, link + pin, class: li_class, data: li_data)
  end

  # Unified pin control. Pinned: permanently visible, subtle gray pin
  # (click = unpin). Not pinned: an outline pin only on hover (click = pin).
  # This way no second, bold pin icon appears on hover.
  # @param group [String] name of the container's Tailwind group ('proj' | 'sec')
  def pin_toggle(group:, section: nil)
    pinned = section ? section_pinned?(section) : project_pinned?
    label = if pinned
              t(section ? 'navigation.unpin_section' : 'navigation.unpin_project')
            else
              t(section ? 'navigation.pin_section' : 'navigation.pin_project')
            end
    base = 'flex items-center justify-center w-6 h-6 shrink-0 text-cream-700 hover:text-heading transition-colors'
    visibility = if pinned
                   ''
                 elsif group == 'sec'
                   'opacity-0 group-hover/sec:opacity-100 focus:opacity-100'
                 else
                   'opacity-0 group-hover/proj:opacity-100 focus:opacity-100'
                 end
    icon = 'bi-pin-angle' # uniformly light outline pin; status only via visibility

    helpers.button_to(sidebar_pins_path,
                      method: :patch,
                      params: { project_id: @project.id, section: section }.compact,
                      form: { class: 'contents' },
                      class: "#{base} #{visibility}".strip,
                      title: label,
                      aria: { label: label }) do
      helpers.content_tag(:i, '', class: "bi #{icon} text-[10px]")
    end
  end

  def link_classes(tab)
    sidebar_row_classes(active: active?(tab), spacing: nil)
  end

  # The tab is no longer part of the answer: the row's own state colours its
  # icon (components/sidebar_nav.css). Kept in the signature because the
  # template calls it per item, like link_classes beside it.
  def icon_classes(_tab)
    sidebar_row_icon_classes
  end

  # Dashboard path of the project. ONE source, used by the header link AND the
  # dashboard menu item (NAV_ITEMS), so that the two never diverge.
  def project_dashboard_path
    helpers.organisation_project_path(organisation_id: @project.organisation_id, id: @project.id)
  end

  # Navigation data for another surface. Uses the same gates and paths as
  # the sidebar without rendering its tree (and its pin forms) for each link.
  def navigation_items(view_context:)
    @navigation_context = view_context
    (render_items + more_items).map do |item|
      { key: item[:tab], label: view_context.t(item[:i18n]), path: nav_item_path(item) }
    end
  ensure
    @navigation_context = nil
  end

  def nav_item_path(item)
    send(item[:path])
  end

  private

  def helpers
    @navigation_context || super
  end

  def accessible_nav_items
    NAV_ITEMS.select { |i| tab_accessible?(i[:tab]) }
  end

  def accessible_more_items
    MORE_ITEMS.select { |i| send(i[:perm]) }
  end

  # Single mapping tab -> access, used by pinned_sections AND
  # accessible_nav_items (previously duplicated as nav_accessible?/section_accessible?).
  # Dashboard is always reachable, since the project itself is visible in the list.
  def tab_accessible?(tab)
    case tab
    when 'dashboard'     then true
    when 'tickets'       then can_tickets?
    when 'knowledge'     then can_knowledge?
    when 'documentation' then can_documentation?
    when 'meetings'      then can_meetings?
    else false
    end
  end

  def active?(tab)
    current? && @current_tab == tab
  end

  def proj_policy
    @proj_policy ||= helpers.policy(@project)
  end

  # Read OR write access to a policy area (the recurring pattern,
  # bundled once instead of "read || write" everywhere).
  def area_rw?(area)
    proj_policy.area_access?(area, :read) || proj_policy.area_access?(area, :write)
  end

  # Permissions, memoized. DELIBERATELY one explicit method each (instead of
  # metaprogramming), so that on reading it is immediately clear which area is checked.
  # ALL current-independent: an item is reachable if the permission
  # holds — regardless of whether the project is currently open (consistent behavior,
  # you can jump into any project from anywhere).
  def can_tickets?
    return @can_tickets if defined?(@can_tickets)

    @can_tickets = area_rw?(:tickets)
  end

  def can_knowledge?
    return @can_knowledge if defined?(@can_knowledge)

    @can_knowledge = area_rw?(:notes) || area_rw?(:documents)
  end

  def can_documentation?
    return @can_documentation if defined?(@can_documentation)

    @can_documentation = area_rw?(:documentation)
  end

  def can_meetings?
    return @can_meetings if defined?(@can_meetings)

    @can_meetings = area_rw?(:meetings)
  end

  def can_members?
    return @can_members if defined?(@can_members)

    @can_members = area_rw?(:members)
  end

  def can_settings?
    return @can_settings if defined?(@can_settings)

    @can_settings = helpers.current_user.has_permission_in_organisation?(@project.organisation, 'projects', 'change_project_properties')
  end

  def can_activities?
    return @can_activities if defined?(@can_activities)

    @can_activities = proj_policy.view_activities?
  end

  # Path helpers: one explicit helper per route -> directly readable (DELIBERATELY not
  # bundled via metaprogramming). project_dashboard_path is public,
  # because the header link uses it too.
  def tickets_path
    helpers.organisation_project_tickets_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end

  def knowledge_path
    helpers.organisation_project_knowledge_index_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end

  def documentation_path
    helpers.organisation_project_documentation_index_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end

  def meetings_path
    helpers.organisation_project_meetings_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end

  def members_path
    helpers.organisation_project_project_permissions_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end

  def settings_path
    helpers.edit_organisation_project_path(organisation_id: @project.organisation_id, id: @project.id)
  end

  def activities_path
    helpers.organisation_project_activities_path(organisation_id: @project.organisation_id, project_id: @project.id)
  end
end
