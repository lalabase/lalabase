# frozen_string_literal: true

# The two forms of a ticket list column (doc/spaltenwahl_plan.md, S1): the cell
# in the header row's column, and the item below the title that shows the same
# field once the width has run out. One case per field, so a new column type
# gets both forms in one place, and the row partial only decides where each
# form goes.
module TicketColumnsHelper
  # How many ranked columns the header row shows before the picker's fit rule
  # has measured anything: all of them with the detail closed, one with it open
  # (the compact rule the list had before). lib/column_picker/fit.js corrects
  # the number on the first paint.
  INITIAL_FIT_NARROW = 1

  # A cell without a value shows NOTHING (designer, 07.09.2026). It used to
  # carry an en dash, on the argument that a dash reads as "nothing here" while
  # an empty cell might read as "not loaded". In a table it does not: an empty
  # cell is already the sign for nothing, and a column of pale dashes down a
  # list is a dozen characters of noise saying what the blank says by itself.
  # Same for "ohne Zuweisung", which was the word for an empty value.

  def initial_column_fit(ranked_columns, content_open:)
    content_open ? [INITIAL_FIT_NARROW, ranked_columns.size].min : ranked_columns.size
  end

  # The column's minimum width as a CSS variable the compact layout reads
  # (Tailwind is precompiled, so a computed width class would not exist).
  # The share a ranked column takes of the table in full mode (the lane shut),
  # read by ONE rule in layout.css ("Full mode"); compact mode reads --col-min
  # alone. custom_status is the project's status column: at a tenth of the
  # table "In Bearbeitung" was cut to 78px while the title had room, and 106px
  # is what the word needs (designer, 09.09.2026), so 14%; the title gives.
  COLUMN_SHARE = {
    'assignees' => '12%', 'time_spent' => '8%', 'subtask_count' => '6%', 'waiting' => '6%', 'custom_status' => '14%'
  }.freeze
  DEFAULT_COLUMN_SHARE = '10%'

  def column_min_width_style(column)
    "--col-min: #{column[:min_width]}px; --col-share: #{COLUMN_SHARE.fetch(column[:key].to_s, DEFAULT_COLUMN_SHARE)}"
  end

  # Columns whose value is a QUANTITY. A number is read from its last digit, so
  # it lines up on the right - and the head over it goes right with it, or the
  # label points at nothing. The column's TYPE decides this, never its key: the
  # next duration column is aligned without a second entry, and a list of keys
  # is how a rule turns into a table of exceptions.
  NUMERIC_COLUMN_TYPES = %w[duration count].freeze

  def column_numeric?(column)
    NUMERIC_COLUMN_TYPES.include?(column[:type].to_s)
  end

  def column_align_class(column)
    column_numeric?(column) ? 'text-end' : 'text-start'
  end

  # The label OVER the column, which is a different job from the label the
  # column picker and the in-app help use: the picker explains what a column
  # holds ("Erfasste Zeit"), the head only has to name it inside a fixed cell,
  # and "ERFASSTE ZEIT" does not fit 90px - it broke into a second line and
  # lost it. So: the picker's name by default, a short form only where the cell
  # forces one. A column head is never cut off.
  def column_head_label(column)
    I18n.t("models.view_configuration.column_headers.#{column[:key]}", default: column[:label])
  end

  # === The value as ONE line, under the title ===
  #
  # What a column shows when there is no room for the column itself
  # (designer, 07.09.2026, "Spaltenpanel: Anpinnen einbauen" § 4). Plain text,
  # not the cell's markup: an avatar, a share bar or a status pill in an 11px
  # line under the title would make the row two things at once.
  #
  # ⚠️ A row carried BOTH forms until this morning - the cell AND an item under
  # the title, always, whether the cell showed or not. That is what turned every
  # row into three or four lines the moment the lane opened, and why the item
  # was removed (72058144). It is back with the rule it was missing: the item
  # shows exactly when its cell does NOT (layout.css, "Column fit"), the line
  # never wraps, and a value that is empty is left out rather than spelled.
  def ticket_column_meta_text(ticket, column)
    case column[:key]
    when 'assignees'
      viewer_ordered_users(ticket.assignees).map { |assignee| viewer_display_name(assignee) }.join(', ').presence
    when 'tags'
      ticket.tags.map(&:name).join(', ').presence
    when 'created_at' then meta_date(ticket.created_at)
    when 'updated_at' then meta_date(ticket.updated_at)
    when 'time_spent'
      totals = ticket_time_totals(ticket)
      return unless totals[:minutes].positive?

      tag.span(TimeSession.format_duration(totals[:minutes]), class: 'font-mono')
    when 'billing_status'
      totals = ticket_time_totals(ticket)
      time_billing_state_label(totals[:billing_status], percent: totals[:percent])
    when 'subtask_count'
      counts = ticket_subtask_counts(ticket)
      return unless counts[:total].positive?

      tag.span(t('views.organisations.tickets.tickets_results.subtask_count_meta', **counts), class: 'font-mono')
    when 'waiting'
      # Words, not the hourglass: alone in a line of other values, a bare "2" says nothing.
      waiting_on = ticket_waiting_count(ticket)
      return unless waiting_on.positive?

      t('views.organisations.tickets.tickets_results.waiting_meta', count: waiting_on)
    else
      return unless column[:custom]

      name = custom_attribute_name(column)
      value = ticket.get_custom_attribute(name)
      custom_attribute_text(ticket, name, value).presence if value.present?
    end
  end

  # The field as a cell of its own column.
  def ticket_column_cell(ticket, column)
    case column[:key]
    when 'assignees'
      return empty_cell if ticket.assignees.empty?

      # Adaptive (user, 08.09.2026): one person as chip+name, several as chips
      # only, the viewer first. Two names never fit the 120px column.
      tag.div(viewer_user_list(ticket.assignees, size: :xs), class: 'text-sm text-body truncate')
    when 'tags'
      return empty_cell if ticket.tags.empty?

      tag.div(class: 'flex gap-1 overflow-hidden') do
        safe_join(ticket.tags.map { |tag_record| render(NeoTagComponent.new(text: tag_record.name, variant: :warning, size: :small)) })
      end
    when 'created_at' then date_cell(ticket.created_at)
    when 'updated_at' then date_cell(ticket.updated_at)
    when 'time_spent'
      totals = ticket_time_totals(ticket)
      return empty_cell unless totals[:minutes].positive?

      # Links into the time list rather than opening the ticket: the row
      # controller ignores clicks on <a>. Same address as the hours chip.
      link_to(TimeSession.format_duration(totals[:minutes]), subject_time_list_path(ticket),
              class: 'text-sm tabular-nums text-body hover:text-heading hover:underline',
              title: t('views.organisations.tickets.tickets_results.time_spent_title'),
              data: { turbo_frame: '_top' })
    when 'billing_status'
      # Same bar and same word as the time list this column links into.
      totals = ticket_time_totals(ticket)
      label = time_billing_state_label(totals[:billing_status], percent: totals[:percent])
      return empty_cell unless label

      tag.span(class: 'inline-flex items-center gap-2 whitespace-nowrap text-xs text-body') do
        safe_join([render(NeoTimeShareBarComponent.new(shares: totals[:shares])), label], ' ')
      end
    when 'subtask_count'
      # A ticket without sub-tickets shows nothing, and so does every sub-ticket
      # (one level deep, Ticket#parent_is_top_level): "0/0" in most rows would
      # be the column of placeholders the note at the top rules out.
      counts = ticket_subtask_counts(ticket)
      return empty_cell unless counts[:total].positive?

      tag.span(t('views.organisations.tickets.tickets_results.subtask_count_cell', **counts),
               class: 'text-sm tabular-nums text-body',
               title: t('views.organisations.tickets.shared.subtasks.progress', **counts))
    when 'waiting'
      # The hourglass and the number of open tickets this one waits on (plan §8.3). Nothing
      # while it waits on none, which is most rows; "blocking" is the filter's, not this column's.
      return empty_cell unless ticket_waiting_count(ticket).positive?

      ticket_waiting_mark(ticket, count: true)
    else
      return unless column[:custom]

      name = custom_attribute_name(column)
      value = ticket.get_custom_attribute(name)
      value.present? ? render_custom_attribute_value(ticket, name, value) : empty_cell
    end
  end

  private

  def inline_item(icon, content)
    safe_join([tag.i(class: "bi #{icon} text-[10px]"), content], ' ')
  end

  def inline_labelled(column, content)
    safe_join(["#{column[:label]}:", content], ' ')
  end

  # ⚠️ BOTH forms use display_time_SPLIT, and the compact one did not until
  # 07.09.2026. Split means the clock sits in its own span (.date-time-part),
  # which is the only way the stylesheet can drop it - a whole formatted string
  # cannot be taken apart in CSS. The reader's own date format still decides how
  # the DATE is written; the list just never shows a time (user, 07.09.2026).
  def meta_date(time)
    return if time.blank?

    tag.span(display_time_split(time, area: 'ticket_list_compact', user: current_user), class: 'font-mono')
  end

  def date_cell(time)
    tag.div(class: 'text-sm') do
      safe_join([
                  tag.span(display_time_split(time, area: 'ticket_list_large', user: current_user), class: 'date-full'),
                  tag.span(display_time_split(time, area: 'ticket_list_compact', user: current_user), class: 'date-compact hidden')
                ])
    end
  end

  # Nothing, and nothing is the point (see the note at the top of this file).
  # A method rather than a bare nil at five call sites, so the decision has one
  # place to be read and one place to be taken back.
  def empty_cell
    nil
  end

  def custom_attribute_name(column)
    column[:key].to_s.delete_prefix('custom_')
  end

  # The value of a custom attribute as plain text, for the item below the
  # title: the option's label for a select, a mark for a checkbox, the reader's
  # date format for a date, otherwise the value itself.
  def custom_attribute_text(ticket, name, value)
    attr_def = ticket.attribute_definitions.find { |ad| ad.name == name }
    return value.to_s unless attr_def

    case attr_def.field_type
    when 'select', 'multiselect' then attr_def.display_value(value).to_s
    when 'checkbox' then [true, 'true', '1'].include?(value) ? '✓' : '✗'
    when 'currency' then number_to_currency(value, unit: '€', format: '%n %u')
    when 'percentage' then "#{value}%"
    when 'date'
      begin
        # A date, and only a date: display_time would append the area's %H:%M
        # and print "00:00" after a value that never had a time.
        display_date(Date.parse(value.to_s), area: 'ticket_list_large', user: current_user)
      rescue ArgumentError
        value.to_s
      end
    else value.to_s
    end
  end
end
