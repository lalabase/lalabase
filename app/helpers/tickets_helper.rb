# frozen_string_literal: true

module TicketsHelper
  # People who may be assigned to a ticket of this project.
  #
  # The source is Project#assignable_users: the canonical inverse users_with_access (org
  # admins, global role permissions and direct ProjectPermissions), narrowed to active
  # members. As a result the picker leaks no people from other projects, and the board,
  # the head menu and the bulk panel offer the same people.
  #
  # Already assigned people are always kept (union with assignee_ids), even
  # if they are no longer in the scope — otherwise an edit would silently remove them on save,
  # because collection_select discards values that are not listed. The write keeps them too:
  # Ticket#assignable_user_ids takes whoever is assigned already.
  #
  # DELIBERATELY ONLY for persisted? tickets: the assignee_ids of an unsaved ticket come
  # from user input (form re-render) and could contain arbitrary IDs — if we unioned them,
  # someone could smuggle foreign names into the selection list. Only the already
  # saved (trusted) assignments extend the scope.
  # The width of the fixed cells (box, number, title) the column fit script
  # subtracts before it decides how many ranked columns fit. Whether there is a
  # box is the controller's answer (TicketListColumns#ticket_list_selectable?).
  def ticket_list_fixed_width_px(project)
    ViewConfiguration::COLUMN_MIN_WIDTH_PX['number'] +
      ViewConfiguration::COLUMN_MIN_WIDTH_PX['title'] +
      (ticket_list_selectable?(project) ? ViewConfiguration::SELECT_COLUMN_WIDTH_PX : 0)
  end

  def assignable_users_for(project, ticket = nil)
    ids = project.assignable_users.ids
    ids |= ticket.assignee_ids if ticket&.persisted?
    User.where(id: ids).order(:first_name, :last_name)
  end

  # CSS classes for ticket highlighting based on system functions.
  # Always returns a background (bg-surface-raised as the default) so that
  # calling templates don't have to set their own bg-surface-raised.
  #
  # For <a>/<div> containers (dashboard): ticket_highlight_classes → full set
  # For <tr> rows (ticket list): ticket_row_highlight_bg → only background
  #                              ticket_row_highlight_border → only border (for the first <td>)
  # High priority = a thin red left spine only. The former bg-red-50 FLOOD was removed so the
  # red "overdue" chip stays unambiguous next to it (form/position separate the two reds, not
  # a shared fill). Priority LEVEL itself now reads from the signal bars (NeoPriorityBarsComponent).
  HIGH_PRIORITY_HIGHLIGHT = 'border-l-4 border-l-red-400 bg-surface-raised'
  HIGH_PRIORITY_BG = ''
  HIGH_PRIORITY_BORDER = 'border-l-4 border-l-red-400'

  def ticket_highlight_classes(ticket)
    return 'bg-surface-raised' unless ticket.respond_to?(:has_system_function?)
    return HIGH_PRIORITY_HIGHLIGHT if ticket.has_system_function?(SystemFunctions::Registry::HIGH_PRIORITY)

    'bg-surface-raised'
  end

  def ticket_row_highlight_bg(ticket)
    return '' unless ticket.respond_to?(:has_system_function?)
    return HIGH_PRIORITY_BG if ticket.has_system_function?(SystemFunctions::Registry::HIGH_PRIORITY)

    ''
  end

  def ticket_row_highlight_border(ticket)
    return '' unless ticket.respond_to?(:has_system_function?)
    return HIGH_PRIORITY_BORDER if ticket.has_system_function?(SystemFunctions::Registry::HIGH_PRIORITY)

    ''
  end

  def column_header_class(column)
    case column[:key]
    when 'number'
      # Width comes from layout.css (.list table .number-header, 52px in both
      # modes): a mono number does not grow with the window, so no share here.
      'number-header'
    when 'title'
      # No w-[25%] any more: layout.css sets the title to width auto in both
      # modes (it takes what the ranked columns leave), so the class was dead.
      'title-header'
    # The width of a ranked column is no class any more (designer, 09.09.2026):
    # it is its share of the table, but never less than its minimum, both set
    # as variables by column_min_width_style and read by ONE rule in
    # layout.css. The w-[10%] that stood here was the whole width in a fixed
    # table layout, which reads width alone: the min-w beside it was dead, and
    # "In Bearbeitung" was cut at a tenth of the table while the title had room.
    when 'status'
      'status-header'
    when 'priority'
      'priority-header'
    when 'assignees'
      'assignees-header'
    when 'tags'
      'tags-header'
    when 'created_at'
      'created_at-header'
    when 'updated_at'
      'updated_at-header'
    when 'time_spent'
      'time_spent-header'
    when 'billing_status'
      'billing_status-header'
    else
      # For custom attributes, add the column key as a class
      column[:custom] ? "#{column[:key]}-header" : ''
    end
  end

  # --- What a row counts: booked time, sub-tickets, waiting -----------------
  #
  # What a row needs is what SubjectTimeSummaryService, a ticket's children and
  # Tickets::Waiting answer for ONE ticket. Asking per row costs queries each, on
  # the busiest list in the app, so a list registers its page once
  # (register_ticket_count_page) and each count loads the whole page the first
  # time a cell, a phone row or a board card reads it (Tickets::LazyPagePreload).
  # A count nothing reads costs no query, so what a surface shows decides what is
  # counted, and no list names its counts (third review of #949).
  #
  # A row is rendered from more places than the list (the turbo-stream update
  # after a save, a single row re-render), and those callers register no page.
  # So a miss falls through to a one-ticket lookup instead of an empty cell:
  # every caller is correct without every caller having to be wired. That is the
  # trap this codebase keeps stepping into -- one owner removes the copies, not
  # the wiring.

  def register_ticket_count_page(tickets)
    tickets = tickets.to_a
    ticket_time_totals_cache.register(tickets)
    ticket_subtask_counts_cache.register(tickets)
    ticket_waiting_counts_cache.register(tickets)
    nil
  end

  def ticket_time_totals(ticket)
    ticket_time_totals_cache.fetch(ticket)
  end

  def ticket_subtask_counts(ticket)
    ticket_subtask_counts_cache.fetch(ticket)
  end

  # The waiting column, the board card and the phone row
  # (doc/ticket_relations_plan.md, revision 4, §8.3). The numbers come from
  # Tickets::Waiting only.
  def ticket_waiting_count(ticket)
    ticket_waiting_counts_cache.fetch(ticket)
  end

  def ticket_time_totals_cache
    @ticket_time_totals_cache ||= TimeSessions::SubjectTotalsCache.new(user: current_user)
  end

  def ticket_subtask_counts_cache
    @ticket_subtask_counts_cache ||= Tickets::SubtaskCountsCache.new
  end

  def ticket_waiting_counts_cache
    @ticket_waiting_counts_cache ||= Tickets::WaitingCountsCache.new
  end

  def sortable_column?(column_key)
    return true if %w[number title created_at updated_at].include?(column_key)

    # Custom select attributes (status/priority and their 'custom_'-prefixed column
    # keys) sort by their configured option order — see Ticket.sortable_custom_attribute.
    Ticket.sortable_custom_attribute(column_key).present?
  end

  # A configured value wears its colour as a DOT, not as a filled pill.
  #
  # ⚠️ Filled pills were what the list looked like until 07.09.2026, and the
  # detail's status has read as a dot for longer than that - so the same value
  # had two forms depending on where you looked. A pill also spends its colour
  # on a whole surface: four of them in a row and the eye has nowhere quiet to
  # rest, which is the complaint the ticket list drew. The dot carries the same
  # information in the same colour and leaves the word as a word.
  #
  # The colour arrives as an inline style (a configured hex from the attribute
  # definition) or as a Tailwind bg- class (the system-function map). Never
  # both.
  def attribute_value_with_dot(label, chip_size, style: nil, dot_class: nil)
    dot = content_tag(:span, '',
                      class: ['inline-block h-2 w-2 flex-shrink-0 rounded-full', dot_class].compact.join(' '),
                      style: style)
    # text-body, not muted: the word is text and reads at full strength, the
    # dot in front of it carries the signal (designer, 07.09.2026). Half the
    # table used to sit at about 3:1 because every value was a quiet grey.
    content_tag :span, class: "inline-flex items-center gap-1.5 #{chip_size} text-body min-w-0" do
      safe_join([dot, content_tag(:span, label, class: 'truncate')])
    end
  end

  # context: :list (default, table/kanban cells, text-xs) or :header (the ticket
  # header meta row: 13px, cream ink, dates/numbers in mono — one look for every
  # value in that row, user 04.09.2026).
  def render_custom_attribute_value(ticket, attribute_name, value, display_mode: 'colored', context: :list)
    attr_def = ticket.attribute_definitions.find { |ad| ad.name == attribute_name }
    return value unless attr_def

    chip_size = context == :header ? 'text-[13px] text-cream-700' : 'text-xs'
    date_chip = context == :header ? "font-mono #{chip_size}" : chip_size

    case attr_def.field_type
    when 'select', 'multiselect'
      option = attr_def.allowed_values.find { |v| v['value'] == value }
      label = attr_def.display_value(value)

      # The system's ladder before a colour stored on the option (surface
      # table F16, 08.09.2026): a state the system knows never carries a hex
      # value into the markup; a stored colour only serves an option without
      # a system function.
      if display_mode == 'text'
        content_tag :span, label, class: 'text-xs text-body truncate block'
      elsif display_mode == 'colored' && (dot_css = system_function_dot_color(attr_def, value))
        attribute_value_with_dot(label, chip_size, dot_class: dot_css)
      elsif option && (color = TicketAttributeDefinition.safe_option_color(option['color']))
        attribute_value_with_dot(label, chip_size, style: "background-color: #{color}")
      elsif display_mode == 'colored' && (badge_css = system_function_badge_color(ticket, attr_def, value))
        # The badge's own fill is the dot's colour; its text half is dropped,
        # because the label is no longer standing on that fill.
        attribute_value_with_dot(label, chip_size, dot_class: badge_css[/\bbg-\S+/])
      else
        content_tag :span, label, class: 'text-xs truncate block'
      end
    when 'currency'
      content_tag :span, number_to_currency(value, unit: '€', format: '%n %u'), class: "#{chip_size} font-mono"
    when 'percentage'
      content_tag :span, "#{value}%", class: "#{chip_size} font-mono"
    when 'date'
      # The deadline date renders as the overdue-aware chip (red calendar-x when past due);
      # any other date field stays a plain formatted date.
      if attribute_name == Ticket::DUE_DATE_KEY && (badge = ticket_due_badge(ticket, context: context))
        badge
      else
        content_tag :span, Date.parse(value).strftime('%d.%m.%Y'), class: date_chip
      end
    when 'datetime'
      # In the header the datetime follows the user's ticket_header format, like
      # the created/updated chips next to it; lists keep the fixed short form.
      formatted = if context == :header
                    display_time(DateTime.parse(value), area: :ticket_header, user: current_user)
                  else
                    DateTime.parse(value).strftime('%d.%m.%Y %H:%M')
                  end
      content_tag :span, formatted, class: date_chip
    when 'checkbox'
      if [true, 'true', '1'].include?(value)
        content_tag :i, '', class: 'bi bi-check-circle-fill text-green-600'
      else
        content_tag :i, '', class: 'bi bi-circle text-gray-400'
      end
    else
      content_tag :span, value.to_s.truncate(50), class: chip_size, title: value.to_s
    end
  rescue JSON::ParserError
    # If JSON parsing fails, just display the value as is
    content_tag :span, value.to_s, class: chip_size
  end

  # Linear-style priority signal bars for a ticket, or nil when it has no leveled priority.
  # Resolves the priority definition through the ticket's MEMOIZED attribute_definitions so a
  # list/board with preloaded project definitions issues no extra query per row (see F6).
  def ticket_priority_bars(ticket)
    return unless ticket.respond_to?(:attribute_definitions)

    value = ticket.get_custom_attribute('priority')
    return if value.blank?

    definition = ticket.attribute_definitions.find { |ad| ad.name == 'priority' && ad.field_type == 'select' }
    level = definition&.level_for(value)
    return unless level

    option = definition.allowed_values.find { |opt| opt['value'] == value }
    label = "#{t('views.helpers.application.priority_label')}: #{definition.display_value(value)}"
    color = TicketAttributeDefinition.safe_option_color(option&.dig('color'))
    render(NeoPriorityBarsComponent.new(level: level[:index], total: level[:total], color: color, label: label))
  end

  # Due-date chip: red "overdue" (calendar-x icon) when past due and not done, otherwise a
  # neutral due chip (calendar icon). nil when the ticket has no due date. Reads ticket.overdue?
  # (per-project closed-status aware) so completed tickets never show red.
  # context: :list (default) or :header — see render_custom_attribute_value.
  def ticket_due_badge(ticket, context: :list)
    return unless ticket.respond_to?(:due_on)

    date = ticket.due_on
    return if date.nil?

    overdue = ticket.overdue?
    full_date = date.strftime('%d.%m.%Y')
    # Board cards are compact: day.month only, and the "overdue" WORD moves into the
    # tooltip -- icon + red already carry the signal, and repeating the word on most
    # cards would drain the red channel of meaning (P11).
    formatted = context == :board ? date.strftime('%d.%m.') : full_date
    icon = overdue ? 'calendar-x' : 'calendar-event'
    text_class = if overdue
                   'text-red-700'
                 elsif context == :header
                   'text-cream-700'
                 elsif context == :board
                   'text-cream-500'
                 else
                   'text-gray-500'
                 end
    size_class = case context
                 when :header then 'font-mono text-[13px]'
                 when :board then 'text-[11px]'
                 else 'text-xs'
                 end
    chip_title = if overdue
                   context == :board ? "#{t('views.organisations.tickets.overdue')} (#{full_date})" : t('views.organisations.tickets.overdue')
                 else
                   t('views.organisations.tickets.due_on', date: full_date)
                 end

    content_tag :span, class: "ticket-due-badge inline-flex items-center gap-1 #{size_class} #{text_class}", title: chip_title do
      safe_join([
        content_tag(:i, '', class: "bi bi-#{icon}", 'aria-hidden': 'true'),
        content_tag(:span, formatted),
        (overdue && context != :board ? content_tag(:span, t('views.organisations.tickets.overdue'), class: 'font-medium') : nil)
      ].compact)
    end
  end

  # === The deadline sign in front of a list title ===
  #
  # It replaces the red bar that used to sit at the row's left edge (designer,
  # 07.09.2026). Three things were wrong with that bar and all three are the
  # reason not to build another one:
  #   - it sat OUTSIDE the text edge and broke the one left edge that the column
  #     head and the title start on;
  #   - it was colour without a word, so one had to know the code;
  #   - ⚠️ and it did not even mean what it looked like: it marked HIGH PRIORITY
  #     (SystemFunctions::Registry::HIGH_PRIORITY), not a deadline. Removing it
  #     leaves high priority without a mark of its own in the row; it shows in
  #     the priority column when that column is chosen.
  #
  # Two states, two colours - a deadline today is an announcement, a deadline
  # passed is a failure, and they must not wear the same red. Nothing else gets
  # a sign, and no placeholder either: without a deadline the title starts at
  # the cell edge.
  DEADLINE_FLAG_COLORS = { overdue: '#A03227', due_today: '#C08A3E' }.freeze
  DEADLINE_FLAG_SIZE_PX = 12
  DEADLINE_FLAG_STROKE = '1.9'

  # nil unless the ticket has a deadline that is today or past. `suppressed:`
  # is the caller's answer to "does this row already say it somewhere else" -
  # see ticket_deadline_flag_suppressed?.
  def ticket_deadline_flag(ticket, suppressed: false)
    return if suppressed

    date = ticket.due_on
    return if date.nil? || ticket.done?

    state = if date < Date.current
              :overdue
            elsif date == Date.current
              :due_today
            end
    return if state.nil?

    label = if state == :overdue
              t('views.organisations.tickets.overdue_since', date: l(date, format: :default))
            else
              t('views.organisations.tickets.due_today')
            end

    # The word twice on purpose: `title` for the pointer, `aria-label` for the
    # keyboard and the screen reader, which never see a tooltip. The sign is not
    # a focus target of its own - the whole row is clickable and carries it.
    content_tag(:span, deadline_flag_svg(DEADLINE_FLAG_COLORS[state]),
                class: 'ticket-deadline-flag', title: label, role: 'img', 'aria-label': label)
  end

  # The two cases where the sign would be a SECOND statement about the same
  # thing, and one statement is the rule:
  #   - the "due" column is on screen, and a date in it already carries the
  #     state in its own colour;
  #   - the view being read is itself a deadline question (a saved view called
  #     "Overdue", an ad-hoc condition on the due field), so every row would
  #     carry the sign and it would say nothing.
  def ticket_deadline_flag_suppressed?(columns, filtered_keys = nil)
    due_key = "custom_#{Ticket::DUE_DATE_KEY}"
    return true if Array(columns).any? { |column| column[:key].to_s == due_key }

    # Deliberately a substring: the same condition is spelled several ways
    # depending on where it came from (the column key, the bare attribute name,
    # the bar's "due_preset_overdue" shortcut). Matching them exactly would mean
    # keeping a list of spellings in step with three other places.
    Array(filtered_keys).any? { |key| key.to_s.include?(Ticket::DUE_DATE_KEY) }
  end

  def deadline_flag_svg(color)
    size = DEADLINE_FLAG_SIZE_PX
    tag.svg(width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
            stroke: color, 'stroke-width': DEADLINE_FLAG_STROKE,
            'stroke-linecap': 'round', 'stroke-linejoin': 'round',
            'aria-hidden': 'true', focusable: 'false') do
      safe_join([
                  tag.path(d: 'M4 22V4'),
                  tag.path(d: 'M4 4h11l-2 4 2 4H4')
                ])
    end
  end

  # Returns badge styling (CSS classes or inline style hash) for a status option value.
  # Used by inline status badge dropdown.
  def status_badge_style(attr_def, value)
    option = attr_def.allowed_values.find { |v| v['value'] == value }
    return {} unless option

    # 1. The system's ladder for a state the system knows (F16)
    system_functions = option['system_functions'] || []
    system_functions.each do |fn_key|
      css = TicketColorMap::SYSTEM_FUNCTION_BADGE_COLORS[fn_key]
      return { class: css } if css
    end

    # 2. A colour stored on an option without a system function. Only a hex value reaches
    # the style: a legacy row with anything else falls through to the name-based colour.
    if (color = TicketAttributeDefinition.safe_option_color(option['color']))
      return { style: "background-color: #{color}; color: #{text_color_for_background(color)}" }
    end

    # 3. Fallback name-based color
    css = TicketColorMap::STATUS_COLORS[value.to_s.downcase]
    if css
      text = css.include?('green') || css.include?('gray') ? 'text-on-fill' : 'text-cream-900'
      return { class: "#{css} #{text}" }
    end

    {}
  end

  # The dot's class for a value the system knows by its function (the ladder
  # at dot strength), nil for any other value.
  def system_function_dot_color(attr_def, value)
    functions = attr_def.allowed_values.find { |v| v['value'] == value }&.dig('system_functions') || []
    functions.each do |fn_key|
      css = TicketColorMap::SYSTEM_FUNCTION_DOT_COLORS[fn_key]
      return css if css
    end
    nil
  end

  # Returns CSS badge classes for a custom attribute value based on System Functions or TicketColorMap.
  # Returns nil if no color mapping exists.
  def system_function_badge_color(_ticket, attr_def, value)
    system_functions = attr_def.allowed_values
                               .find { |v| v['value'] == value }
                               &.dig('system_functions') || []

    # Try System-Function-based badge colors first
    system_functions.each do |fn_key|
      css = TicketColorMap::SYSTEM_FUNCTION_BADGE_COLORS[fn_key]
      return css if css
    end

    # Fallback to name-based color maps (status/priority)
    case attr_def.name
    when 'status'
      css = TicketColorMap::STATUS_COLORS[value.to_s.downcase]
      return "#{css} #{css&.include?('green') || css&.include?('gray') ? 'text-on-fill' : 'text-cream-900'}" if css
    when 'priority'
      return TicketColorMap.priority_badge_color(value)
    end

    nil
  end

  def text_color_for_background(hex_color)
    return '#000000' if hex_color.blank?

    # Remove # if present
    hex = hex_color.gsub('#', '')

    # Convert to RGB
    r = hex[0..1].to_i(16)
    g = hex[2..3].to_i(16)
    b = hex[4..5].to_i(16)

    # Calculate luminance
    luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255

    # Return black for light backgrounds, white for dark
    luminance > 0.5 ? '#000000' : '#FFFFFF'
  end

  # Generates a ticket link with correct Turbo Frame parameters
  # This ensures that clicking the link loads the ticket
  # in the content frame instead of reloading the whole page
  def ticket_turbo_frame_path(organisation, project, ticket, options = {})
    organisation_project_ticket_path(organisation, project, ticket, options)

    # Add a ticket_id parameter for correct Turbo Frame navigation
    params = options.merge(ticket_id: "#{ticket.id}.turbo_stream?frame=content")

    organisation_project_ticket_path(organisation, project, ticket, params)
  end
end
