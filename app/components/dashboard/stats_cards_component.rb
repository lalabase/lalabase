# frozen_string_literal: true

class Dashboard::StatsCardsComponent < ViewComponent::Base
  include DashboardPeriodable

  DEFAULT_CARDS = %w[tickets notes open_hours documents].freeze

  SCOPE_OPTIONS = [
    ['all',  'dashboard.stat_cards.scopes.all'],
    ['mine', 'dashboard.stat_cards.scopes.mine']
  ].freeze

  # Registry of all available statistic cards
  STAT_CARDS = {
    'tickets' => { label_key: 'dashboard.stat_cards.tickets.label', icon: 'bi-check2-square', bg: 'bg-cream-50', permission: { area: :tickets, action: :read },
                   supports_period: true, default_period: 'this_month' },
    'notes' => { label_key: 'dashboard.stat_cards.notes.label', icon: 'bi-journal-text', bg: 'bg-cream-50', permission: { area: :notes, action: :read },
                 supports_period: true, default_period: 'this_month' },
    'documents' => { label_key: 'dashboard.stat_cards.documents.label', icon: 'bi-file-earmark-text', bg: 'bg-cream-50', permission: { area: :documents, action: :read },
                     supports_period: true, default_period: 'this_month' },
    'open_hours' => { label_key: 'dashboard.stat_cards.open_hours.label',     icon: 'bi-hourglass-split', bg: 'bg-cream-50', permission: { area: :time_sessions, action: :read },
                      supports_period: true, default_period: 'all_time',
                      supports_scope: true, default_scope: 'all' },
    'open_tickets' => { label_key: 'dashboard.stat_cards.open_tickets.label', icon: 'bi-exclamation-circle', bg: 'bg-cream-50', permission: { area: :tickets, action: :read },
                        supports_scope: true, default_scope: 'all' },
    'my_tickets' => { label_key: 'dashboard.stat_cards.my_tickets.label',     icon: 'bi-person-check', bg: 'bg-cream-50', permission: { area: :tickets, action: :read },
                      supports_period: true, default_period: 'this_month' },
    'notifications' => { label_key: 'dashboard.stat_cards.notifications.label', icon: 'bi-bell', bg: 'bg-cream-50', permission: nil },
    'activities' => { label_key: 'dashboard.stat_cards.activities.label', icon: 'bi-activity', bg: 'bg-cream-50', permission: nil,
                      supports_period: true, default_period: 'this_week' },
    'my_hours' => { label_key: 'dashboard.stat_cards.my_hours.label', icon: 'bi-clock-history', bg: 'bg-cream-50', permission: { area: :time_sessions, action: :read },
                    supports_period: true, default_period: 'this_week' },
    'billed_time' => { label_key: 'dashboard.stat_cards.billed_time.label', icon: 'bi-cash-stack', bg: 'bg-cream-50', permission: { area: :time_sessions, action: :read },
                       supports_period: true, default_period: 'this_quarter',
                       supports_scope: true, default_scope: 'all' }
  }.freeze

  def initialize(project:, user:, card_settings: nil)
    @project = project
    @user = user
    @card_settings = card_settings || DEFAULT_CARDS.map { |k| { 'key' => k } }
  end

  def should_render?
    visible_cards.any?
  end

  # For show.html.erb: render? checks should_render?
  def visible_cards
    @visible_cards ||= begin
      policy = Current.project_policy(user, project)
      card_settings.filter_map do |setting|
        key = setting['key']
        config = STAT_CARDS[key]
        next unless config

        perm = config[:permission]
        next if perm && !policy.area_access?(perm[:area], perm[:action])

        period = config[:supports_period] ? (setting['period'] || config[:default_period]) : nil
        scope_val = config[:supports_scope] ? (setting['scope'] || config[:default_scope]) : nil

        data = compute_card(key, period: period, scope: scope_val)
        next unless data

        { key: key, config: config, data: data }
      end
    end
  end

  private

  attr_reader :project, :user, :card_settings

  # Status values (downcased) that are "done" (is_completed/is_closed). Memoized per
  # render so the three status cards share one query instead of one each.
  def closed_status_values
    @closed_status_values ||= TicketAttributeDefinition.closed_status_values_for([project.id])
  end

  # Status values (downcased) parked in a backlog (is_backlog). Memoized per render.
  def backlog_status_values
    @backlog_status_values ||= TicketAttributeDefinition.backlog_status_values_for([project.id])
  end

  # "Not active work" = done + backlog. Used to count genuinely open tickets.
  def inactive_status_values
    @inactive_status_values ||= (closed_status_values | backlog_status_values)
  end

  def compute_card(key, period: nil, scope: nil)
    send(:"compute_#{key}", period: period, scope: scope)
  rescue NoMethodError
    nil
  end

  def compute_tickets(period: nil, scope: nil)
    base = project.tickets
    scoped = apply_period(base, period)
    total = scoped.count # ALL tickets, incl. backlog/done — this card is a grand total

    # "Completed" subtitle counts done tickets via the status System Functions
    # (is_completed/is_closed), NOT a hardcoded 'done' value that never matched the
    # seeded options (new/in_progress/resolved/closed) — that was a latent bug.
    # with_status_values returns none for an empty list, so done_count is 0 then.
    done_count = scoped.with_status_values(closed_status_values).count

    { value: total, subtitle: "#{done_count} #{I18n.t('dashboard.stat_cards.tickets.completed')}" }
  end

  def compute_notes(period: nil, scope: nil)
    base = project.notes
    scoped = apply_period(base, period)

    { value: scoped.count,
      subtitle: "#{scoped.where('created_at > ?', 7.days.ago).count} #{I18n.t('dashboard.stat_cards.notes.this_week')}" }
  end

  def compute_documents(period: nil, scope: nil)
    base = project.documents
    scoped = apply_period(base, period)

    { value: scoped.count,
      subtitle: "#{scoped.where('created_at > ?', 30.days.ago).count} #{I18n.t('dashboard.stat_cards.documents.last_month')}" }
  end

  def compute_open_hours(period: nil, scope: nil)
    base = project.time_sessions.unbilled
    base = base.where(creator: user) if scope == 'mine'
    permitted = TimeSessionPolicy::Scope.new(user, base).resolve
    permitted = apply_period(permitted, period, column: 'time_sessions.created_at')
    total_minutes = permitted.sum(:duration)
    hours = (total_minutes / 60.0).round(1)
    open_tickets = permitted.joins(:ticket).distinct.count('tickets.id')

    { value: "#{hours}h",
      subtitle: "#{open_tickets} #{I18n.t('dashboard.stat_cards.open_hours.open_tickets')}" }
  end

  def compute_open_tickets(period: nil, scope: nil)
    # "Open" = active work that is not done: exclude done (completed/closed) AND backlog.
    # NULL-status (untriaged) tickets stay counted as open.
    base = project.tickets.excluding_status_values(inactive_status_values)
    base = base.joins(:ticket_assignments).where(ticket_assignments: { user_id: user.id }) if scope == 'mine'
    open_count = base.count
    high_prio = base.where("custom_attributes->>'priority' IN (?)", %w[high critical]).count

    { value: open_count,
      subtitle: "#{high_prio} #{I18n.t('dashboard.stat_cards.open_tickets.high_priority')}" }
  end

  def compute_my_tickets(period: nil, scope: nil)
    my = project.tickets.joins(:ticket_assignments).where(ticket_assignments: { user_id: user.id })
    my = apply_period(my, period)
    total = my.count # total = all my tickets (incl. backlog/done)
    open_count = my.excluding_status_values(inactive_status_values).count

    { value: total,
      subtitle: "#{open_count} #{I18n.t('dashboard.stat_cards.my_tickets.open')}" }
  end

  def compute_notifications(period: nil, scope: nil)
    # The inbox rule (areas, active projects), narrowed to this project.
    count = Notification.inbox_unread(user, project.organisation).where(project: project).count

    { value: count,
      subtitle: I18n.t('dashboard.stat_cards.notifications.unread') }
  end

  def compute_activities(period: nil, scope: nil)
    ticket_ids = project.tickets.select(:id)
    note_ids = project.notes.select(:id)
    document_ids = project.documents.select(:id)

    base = Activity.feed.where(
      "(trackable_type = 'Ticket' AND trackable_id IN (?)) OR " \
      "(trackable_type = 'Note' AND trackable_id IN (?)) OR " \
      "(trackable_type = 'Document' AND trackable_id IN (?)) OR " \
      "(trackable_type = 'Project' AND trackable_id = ?)",
      ticket_ids, note_ids, document_ids, project.id
    )
    base = apply_period(base, period)
    count = base.count

    { value: count,
      subtitle: I18n.t('dashboard.stat_cards.activities.this_week') }
  end

  def compute_my_hours(period: nil, scope: nil)
    my_sessions = TimeSessionPolicy::Scope.new(user, project.time_sessions.where(creator: user)).resolve
    scoped = apply_period(my_sessions, period, column: 'time_sessions.created_at')
    total_minutes = scoped.sum(:duration)
    hours = (total_minutes / 60.0).round(1)

    { value: "#{hours}h",
      subtitle: I18n.t('dashboard.stat_cards.my_hours.this_week') }
  end

  def compute_billed_time(period: nil, scope: nil)
    base = project.time_sessions.billed
    base = base.where(creator: user) if scope == 'mine'
    permitted = TimeSessionPolicy::Scope.new(user, base).resolve
    permitted = apply_period(permitted, period, column: 'time_sessions.created_at')
    total_minutes = permitted.sum(:duration)
    hours = (total_minutes / 60.0).round(1)
    session_count = permitted.count

    { value: "#{hours}h",
      subtitle: "#{session_count} #{I18n.t('dashboard.stat_cards.billed_time.sessions')}" }
  end
end
