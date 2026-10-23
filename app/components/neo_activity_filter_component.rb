# frozen_string_literal: true

class NeoActivityFilterComponent < ViewComponent::Base
  FILTER_KEYS = %i[view area action_type actor_id period date_from date_to q].freeze
  TAB_BASE_CLASSES = 'h-8 px-3 text-sm inline-flex items-center whitespace-nowrap border-b-2 rounded-t-sm ' \
                     'transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset ' \
                     'focus-visible:ring-ink'
  TAB_ACTIVE_CLASSES = 'border-ink font-semibold text-heading'
  TAB_INACTIVE_CLASSES = 'border-transparent text-muted hover:text-heading'
  PILL_CLASSES = 'inline-flex items-stretch h-7 rounded-full border border-cream-300 bg-transparent ' \
                 'text-[13px] font-normal text-body whitespace-nowrap'
  PILL_BODY_CLASSES = 'inline-flex cursor-pointer list-none items-center gap-1.5 px-2.5 py-1 min-w-0 ' \
                      'hover:bg-surface-raised focus:outline-none focus-visible:ring-2 ' \
                      'focus-visible:ring-inset focus-visible:ring-ink'
  PILL_REMOVE_CLASSES = 'inline-flex items-center justify-center w-[22px] shrink-0 border-l ' \
                        'border-cream-300 text-cream-400 hover:text-heading hover:bg-cream-200 ' \
                        'transition-colors focus:outline-none focus-visible:ring-2 ' \
                        'focus-visible:ring-inset focus-visible:ring-ink'

  AREA_ACTIONS = {
    'tickets' => %w[created updated deleted status_changed priority_changed title_changed description_changed
                    assigned unassigned post_added moved ticket_created ticket_moved_in ticket_moved_out],
    'knowledge' => %w[document_created note_created chat_created meeting_created meeting_deleted
                      meeting_moved_in meeting_moved_out
                      smart_folder_created codebase_imported],
    'times' => %w[created started stopped paused resumed],
    'administration' => %w[member_added member_removed permission_changed role_changed updated]
  }.freeze

  def initialize(current_filters:, filter_url:, result_count: nil, project: nil)
    @current_filters = current_filters.to_h.symbolize_keys.slice(*FILTER_KEYS)
    @filter_url = filter_url
    @result_count = result_count
    @project = project
  end

  private

  attr_reader :current_filters, :filter_url, :result_count, :project

  def tabs
    [
      { key: 'all', label: t('components.neo_activity_filter.tabs.all'), url: filter_url_for(view: nil) },
      { key: 'mine', label: t('components.neo_activity_filter.tabs.mine'), url: filter_url_for(view: 'mine', actor_id: nil) },
      { key: 'tickets', label: t('components.neo_activity_filter.tabs.tickets'), url: filter_url_for(view: 'tickets', area: nil) }
    ]
  end

  def active_tab?(key)
    (current_filters[:view].presence || 'all') == key
  end

  def tab_classes(key)
    "#{TAB_BASE_CLASSES} #{active_tab?(key) ? TAB_ACTIVE_CLASSES : TAB_INACTIVE_CLASSES}"
  end

  def filter_sign_title
    I18n.t('components.filter_bar.filter_sign_title', count: active_chips.size)
  end

  def filter_categories
    [
      { key: :area, label: t('components.neo_activity_filter.categories.area'), options: area_options },
      { key: :action_type, label: t('components.neo_activity_filter.categories.action'), options: action_options },
      { key: :actor_id, label: t('components.neo_activity_filter.categories.actor'), options: actor_options },
      { key: :period, label: t('components.neo_activity_filter.categories.period'), options: period_options }
    ]
  end

  def active_chips
    filter_categories.filter_map do |category|
      value = current_filters[category[:key]]
      next if value.blank?

      selected = category[:options].find { |option| option[:value].to_s == value.to_s }
      label = category[:key] == :period ? formatted_period || selected&.dig(:label) : selected&.dig(:label)
      label ||= custom_chip_label(category[:key], value)
      next if label.blank?

      category.merge(category_label: category[:label], label:, clear_url: clear_url_for(category[:key]))
    end
  end

  def area_options
    option_rows(:area, [
                  [t('components.neo_activity_filter.areas.tickets'), 'tickets'],
                  [t('components.neo_activity_filter.areas.knowledge'), 'knowledge'],
                  [t('components.neo_activity_filter.areas.times'), 'times'],
                  [t('components.neo_activity_filter.areas.administration'), 'administration']
                ]) { |value| area_changes(value) }
  end

  def action_options
    actions = AREA_ACTIONS.fetch(effective_area, AREA_ACTIONS.values.flatten.uniq)
    rows = actions.map { |action| [action_label(action), action] }
    option_rows(:action_type, rows)
  end

  def actor_options
    organisation = project&.organisation || ActsAsTenant.current_tenant
    users = if organisation
              User.joins(:memberships)
                  .where(memberships: { organisation_id: organisation.id, active: true })
                  .distinct
                  .order(:first_name, :last_name)
            else
              User.none
            end

    option_rows(:actor_id, users.map { |user| [helpers.viewer_display_name(user), user.id] }) do |value|
      { actor_id: value, view: (current_filters[:view] == 'mine' ? nil : current_filters[:view]) }
    end
  end

  def period_options
    today = Time.zone.today
    rows = [
      [t('components.neo_activity_filter.periods.last_7_days'), 'last_7_days', today - 6.days, today],
      [t('components.neo_activity_filter.periods.last_30_days'), 'last_30_days', today - 29.days, today],
      [t('components.neo_activity_filter.periods.in_month', month: I18n.l(today, format: '%B')),
       'this_month', today.beginning_of_month, today.end_of_month]
    ]

    rows.map do |label, value, from, to|
      {
        label:,
        value:,
        url: filter_url_for(period: value, date_from: from.iso8601, date_to: to.iso8601),
        selected: current_filters[:period].to_s == value
      }
    end << {
      label: t('components.neo_activity_filter.periods.custom'),
      value: 'custom',
      url: filter_url_for(period: 'custom'),
      selected: current_filters[:period].to_s == 'custom'
    }
  end

  def option_rows(key, rows)
    rows.map do |label, value|
      changes = block_given? ? yield(value) : { key => value }
      {
        label:,
        value:,
        url: filter_url_for(changes),
        selected: current_filters[key].to_s == value.to_s
      }
    end
  end

  def area_changes(value)
    changes = { area: value, view: (current_filters[:view] == 'tickets' && value != 'tickets' ? nil : current_filters[:view]) }
    current_action = current_filters[:action_type]
    changes[:action_type] = nil if current_action.present? && !AREA_ACTIONS.fetch(value).include?(current_action)
    changes
  end

  def effective_area
    return 'tickets' if current_filters[:view] == 'tickets'

    current_filters[:area].to_s
  end

  def action_label(action)
    t("components.neo_activity_filter.actions.#{action}", default: action.humanize)
  end

  def custom_chip_label(key, _value)
    return formatted_period if key == :period

    nil
  end

  def formatted_period
    from = parsed_date(current_filters[:date_from])
    to = parsed_date(current_filters[:date_to])
    return unless from || to
    return I18n.l(from, format: '%d.%m.%Y') if from == to
    return "#{I18n.l(from, format: '%d.%m.')}–#{I18n.l(to, format: '%d.%m.%Y')}" if from && to

    date = from || to
    prefix = from ? t('components.neo_activity_filter.periods.from') : t('components.neo_activity_filter.periods.until')
    "#{prefix} #{I18n.l(date, format: '%d.%m.%Y')}"
  end

  def clear_url_for(key)
    changes = { key => nil }
    changes.merge!(date_from: nil, date_to: nil) if key == :period
    filter_url_for(changes)
  end

  def filter_url_for(changes = {})
    params = current_filters.compact_blank
    changes.each { |key, value| value.present? ? params[key] = value : params.delete(key) }
    query = params.to_query
    query.present? ? "#{filter_url}?#{query}" : filter_url
  end

  def search_hidden_filters
    current_filters.except(:q).compact_blank
  end

  def period_form_hidden_filters
    current_filters.except(:period, :date_from, :date_to).compact_blank
  end

  def parsed_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  public

  def has_active_filters?
    current_filters.except(:view, :q).values.any?(&:present?)
  end

  def clear_filters_url
    params = current_filters.slice(:view, :q).compact_blank
    query = params.to_query
    query.present? ? "#{filter_url}?#{query}" : filter_url
  end

  def formatted_date(date_input)
    parsed_date(date_input)&.strftime('%d.%m.%Y')
  end
end
