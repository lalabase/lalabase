# frozen_string_literal: true

class Dashboard::RecentTicketsComponent < ViewComponent::Base
  include TicketsHelper
  include DashboardPeriodable
  # `turbo_frame_tag` is a Rails view helper and is NOT auto-mixed into ViewComponent;
  # the template wraps its results list in a Turbo frame for the live in-widget search.
  include Turbo::FramesHelper

  DISPLAY_MODES = %w[cards list grouped_status grouped_priority].freeze

  # The tickets list page defaults to this search mode too (title + content + posts).
  SEARCH_MODE = 'content'

  # -- context-free component, all values come from the call site (registry/controller)
  def initialize(project:, user:, display: 'cards', period: nil, limit: nil, search_query: nil, frame_only: false)
    @project = project
    @user = user
    @display = DISPLAY_MODES.include?(display) ? display : 'cards'
    @period = period || 'all_time'
    @limit = limit
    @search_query = search_query.to_s.strip.presence
    @frame_only = frame_only
  end

  def should_render?
    Current.project_policy(user, project).area_access?(:tickets, :read)
  end

  private

  attr_reader :project, :user, :display, :period, :search_query, :frame_only

  def searching?
    search_query.present?
  end

  def recent_tickets
    @recent_tickets ||= searching? ? search_relation.limit(item_limit).to_a : default_recent_tickets
  end

  def default_recent_tickets
    # active_work excludes backlog-parked tickets (this widget shows active work,
    # not the backlog — backlog is groomed on the board/list, not here).
    base = project.tickets.active_work.includes(:assignees, :tags)
    base = apply_period(base, period, column: :updated_at)
    base.order(updated_at: :desc).limit(item_limit)
  end

  # Same engine the tickets list page uses (German FTS + ILIKE fallback for short terms).
  # Deliberately searches ALL of the project's tickets — past the widget's active_work/period
  # narrowing — so the field also finds backlog and closed tickets. current_user decides
  # which private comments may match (Post.readable_by); policy_scope is only needed for
  # smart-folder queries, which this widget never issues.
  def search_relation
    @search_relation ||= TicketSearchQuery.new(
      project, { search: search_query, search_mode: SEARCH_MODE }, { current_user: user }
    ).call
  end

  # Total across all matches, used to decide whether to offer the "view all results" link
  # and to label it. The search narrows the project's tickets without grouping them, so the
  # plain count is the number of tickets.
  def search_total
    @search_total ||= searching? ? search_relation.count : 0
  end

  def more_results?
    searching? && search_total > recent_tickets.size
  end

  # Frame swapped on every search keystroke. Deterministic from the project so the id matches
  # between the initial dashboard render and the endpoint's frame-only re-render. Assumes one
  # recent_tickets widget per project dashboard (realistic); duplicate instances would collide.
  def frame_id
    "recent_tickets_widget_#{project.id}"
  end

  # Base URL the Stimulus controller appends ?q= to. Carries the current display/period/limit so
  # the endpoint reproduces this widget identically (and reverts to the default when q is blank).
  def widget_url
    helpers.organisation_project_dashboard_widget_path(
      current_organisation, project, 'recent_tickets',
      display: display, period: period, limit: item_limit
    )
  end

  # "View all results" target: the real tickets list page, same search string + mode.
  def search_results_path
    helpers.organisation_project_tickets_path(
      current_organisation, project, search: search_query, search_mode: SEARCH_MODE
    )
  end

  # Configured row count for all display modes (one shared limit, decision 3); falls back to the
  # registry default — which is higher for grouped mode — when none is stored or it is invalid.
  def item_limit
    Dashboards::LayoutEngine.effective_item_limit('key' => 'recent_tickets', 'display' => display, 'limit' => @limit)
  end

  def grouped?
    display.start_with?('grouped_')
  end

  def group_attribute
    display == 'grouped_status' ? 'status' : 'priority'
  end

  def grouped_tickets
    @grouped_tickets ||= begin
      groups = recent_tickets.group_by { |t| t.get_custom_attribute(group_attribute).presence || '-' }
      ordered_values = attribute_definition&.allowed_values&.map { |v| v['value'] } || []
      groups.sort_by { |key, _| ordered_values.index(key) || ordered_values.size }
    end
  end

  def attribute_definition
    @attribute_definition ||= project.ticket_attribute_definitions
                                     .active.find_by(name: group_attribute)
  end

  def period_label
    return nil if period == 'all_time'

    key = DashboardPeriodable::PERIOD_OPTIONS.find { |k, _| k == period }&.last
    key ? I18n.t(key) : nil
  end

  def status_dot_color(value)
    TicketColorMap.status_dot_color(value)
  end

  def priority_dot_color(value)
    TicketColorMap.priority_dot_color(value)
  end

  def group_dot_color(value)
    display == 'grouped_status' ? status_dot_color(value) : priority_dot_color(value)
  end

  def can_create_tickets?
    Current.project_policy(user, project).area_access?(:tickets, :write)
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
