# frozen_string_literal: true

# The ticket timeline's row furniture: the day header and the row time.
#
# Why this is a seam and not three components doing the same thing:
# the list groups by calendar day and prints one header per group, so every
# row below it must NOT repeat the date. Until 05.09.2026 each of the three
# item kinds decided that for itself - the post through
# display_time_ago(area: :posts), the activity through
# display_time_ago(area: :activity_logs), the time session with a hardcoded
# strftime - and the list showed relative and absolute times side by side
# under one exact date header. One rule, one owner.
#
# Deliberate: this overrides the per-area date-format preference
# (User::PreferenceStore#date_strftime_format) on this surface. The day header
# already carries the date, so a row format that repeats it has nothing left
# to express, and "vor 2 Monaten" under a header reading "25.06.2026" makes
# the reader reconcile two clocks.
module TimelineHelper
  # Old and new value together, counted as the plain text a reader sees: up to
  # here a change stands in the line ("Status In Arbeit → abgenommen"), above
  # it the line only names the field and the pair moves to the row's
  # disclosure. A limit on the LENGTH, not on the field: a short summary may
  # stand in the line, a long title may not (Aktivitätenfeed, 10.09.2026).
  # And each value on ONE line: a value with a line break is a paragraph, and
  # a paragraph never stands in a line, however short (decision D5 of the
  # width round, 11.09.2026).
  INLINE_CHANGE_LIMIT = 80

  # One field's before/after, carried from this helper (which decides) to the
  # line and the disclosure (which only render). `markdown` marks a model's
  # own text columns, whose values may be Markdown source (a summary, a
  # description). Names - titles, statuses, project names - never are, so a
  # "#103" or a "1. Entwurf" in a title stays exactly as it was typed.
  Change = Data.define(:label, :before, :after, :markdown)

  # What a disclosure holds when there is no pair to compare: the list of
  # changes of a bulk run, or the numbers of the tickets it deleted.
  # NeoActivityChangeDetailsComponent renders it as a label above its text.
  Note = Data.define(:label, :text)

  # The bulk runs the feed shows as ONE line each (doc/ticket_bulk_edit_plan.md,
  # D12), and the parameter holding what that line may have no room for. A move
  # has none on purpose: its sentence already names the project, and the
  # `changes` a move stores would only say the same again.
  BULK_DETAIL_PARAMS = {
    'tickets_bulk_changed' => 'changes',
    'tickets_bulk_undone' => 'changes',
    'tickets_bulk_moved' => nil,
    'tickets_bulk_moved_in' => nil,
    'tickets_bulk_deleted' => 'numbers'
  }.freeze

  # The collapsed-run fields that carry an old and a new value, and where the
  # activity stores them.
  RUN_VALUE_PARAMS = {
    status: %w[from_status to_status],
    priority: %w[from_priority to_priority],
    title: %w[from_title to_title]
  }.freeze

  # The field names (timeline.fields.*) of the run fields that are not a
  # project-configured attribute.
  RUN_FIELD_NAMES = {
    title: 'title',
    description: 'description',
    assignees: 'assignee_ids',
    subscribers: 'subscribers'
  }.freeze

  # The age of one COMMENT row ("vor 4 Minuten"), or nothing for items that
  # only know a day (see TicketTimelineService.date_only?). The exact moment
  # stays reachable as the hover title, so nothing is lost.
  #
  # Mono is for values, proportional for speech (user mockup 05.09.2026): a
  # relative age is a sentence fragment, so it renders proportional; the
  # change rows carry the exact clock time instead (timeline_row_clock).
  def timeline_row_time(item)
    timestamp = TicketTimelineService.timestamp_for(item)
    return '' if timestamp.blank? || TicketTimelineService.date_only?(item)

    timestamp = timestamp.in_time_zone
    tag.time(t('views.common.relative_time_ago', time: time_ago_in_words(timestamp)),
             datetime: timestamp.iso8601,
             title: l(timestamp, format: :long))
  end

  # The clock time of one CHANGE row ("16:07"): a value, so it renders mono,
  # right-aligned by its callers. Nothing for items that only know a day.
  def timeline_row_clock(item)
    timestamp = TicketTimelineService.timestamp_for(item)
    return '' if timestamp.blank? || TicketTimelineService.date_only?(item)

    timestamp = timestamp.in_time_zone
    tag.time(timestamp.strftime('%H:%M'),
             datetime: timestamp.iso8601,
             title: l(timestamp, format: :long))
  end

  # The header above one day group. Numeric on purpose (user mockup
  # 05.09.2026: dates are values, "05.09.2026" even for today) - the named
  # days "Heute"/"Gestern" went with that round.
  def timeline_day_label(date)
    l(date, format: :default)
  end

  # --- Change-row grammar (designer round 05.09.2026) ---
  #
  # Field name first, arrow instead of sentence, display values instead of
  # raw values - and NO actor inside the line: the list appends one only when
  # the person switches, and the ticket title never appears (it stands in the
  # head). One owner for the single row AND the steps inside a collapsed run
  # (NeoActivityRunComponent), so the two can never drift apart.
  #
  # Since 10.09.2026 this helper also decides WHERE a change stands: in the
  # line when it is short, otherwise the line names the field and the pair
  # sits in the row's disclosure. The line (timeline_change_line) and the
  # disclosure (timeline_change_details) read the same pairs through the same
  # test (timeline_change_inline?), so they cannot disagree - and the ticket
  # timeline, which renders the same components, cannot drift from the
  # project feed. A bulk run has no pair; its list follows the same idea with
  # one test of its own (timeline_bulk_detail_fits?) and reaches the
  # disclosure as a Note.

  # The text of one change row. `ticket` resolves attribute labels and
  # display values (project-configured, TicketAttributeDefinition).
  def timeline_change_line(activity, ticket)
    changes = timeline_changes(activity, ticket)
    return timeline_changes_line(changes) if changes.any?

    case activity.action
    when 'description_changed'
      t('views.organisations.tickets.timeline.description_changed_line')
    when 'assigned'
      t('views.organisations.tickets.timeline.assigned_line', name: timeline_secondary_name(activity))
    when 'unassigned'
      t('views.organisations.tickets.timeline.unassigned_line', name: timeline_secondary_name(activity))
    when 'subscriber_added'
      t('views.organisations.tickets.timeline.subscriber_added_line', name: timeline_secondary_name(activity))
    when 'subscriber_removed'
      t('views.organisations.tickets.timeline.subscriber_removed_line', name: timeline_secondary_name(activity))
    when 'created'
      t('views.organisations.tickets.timeline.created_object', kind: timeline_object_type(activity))
    when 'deleted'
      t('views.organisations.tickets.timeline.deleted_object', kind: timeline_object_type(activity))
    when 'post_added', 'comment_added'
      t('views.organisations.tickets.timeline.comment_written')
    when 'ticket_created'
      t('views.organisations.tickets.timeline.ticket_created')
    when 'ticket_moved_in'
      t('views.organisations.tickets.timeline.ticket_moved_in')
    when 'ticket_moved_out'
      t('views.organisations.tickets.timeline.ticket_moved_out')
    when 'document_created', 'document_added'
      t('views.organisations.tickets.timeline.document_created')
    when 'note_created'
      t('views.organisations.tickets.timeline.note_created')
    when 'chat_created'
      t('views.organisations.tickets.timeline.chat_created')
    when 'meeting_created'
      t('views.organisations.tickets.timeline.meeting_created')
    when 'meeting_deleted'
      t('views.organisations.tickets.timeline.meeting_deleted')
    when 'smart_folder_created'
      t('views.organisations.tickets.timeline.smart_folder_created')
    when 'codebase_imported'
      t('views.organisations.tickets.timeline.codebase_imported')
    when 'member_added'
      t('views.organisations.tickets.timeline.member_added', name: timeline_secondary_name(activity))
    when 'member_removed'
      t('views.organisations.tickets.timeline.member_removed', name: timeline_secondary_name(activity))
    when 'permission_changed', 'role_changed'
      t('views.organisations.tickets.timeline.permission_changed', name: timeline_secondary_name(activity))
    when *BULK_DETAIL_PARAMS.keys
      timeline_bulk_line(activity)
    when 'started', 'stopped', 'paused', 'resumed'
      t("views.organisations.tickets.timeline.#{activity.action}")
    else
      activity.message
    end
  end

  # The entries a row's disclosure shows - only what the line could not show
  # itself: several fields at once, one pair too long for the line, or the
  # list of a bulk run that did not fit after its count (a Note). Empty means
  # the row has no disclosure.
  def timeline_change_details(activity, ticket)
    return timeline_bulk_details(activity) if BULK_DETAIL_PARAMS.key?(activity.action)

    changes = timeline_changes(activity, ticket)
    return [] if changes.one? && timeline_change_inline?(changes.first)

    changes
  end

  # THE rule, asked by the line, by the disclosure and by each entry inside
  # it: both values on one line, together at most INLINE_CHANGE_LIMIT
  # characters. A trailing line break ends the one line, it is not a second.
  def timeline_change_inline?(change)
    sides = [change.before, change.after]
    return false if sides.any? { |value| value.is_a?(String) && value.strip.include?("\n") }

    sides.sum { |value| timeline_change_text(change, value).length } <= INLINE_CHANGE_LIMIT
  end

  # Whether one side of a change is Markdown source: the line strips it
  # (timeline_change_text), the disclosure typesets it
  # (NeoActivityChangeDetailsComponent). One answer for both readings.
  def timeline_change_markdown?(change, value)
    change.markdown && value.is_a?(String)
  end

  # "Priorität Niedrig → Normal": the old value struck through, the new one in
  # the heading colour - the eye lands on where things stand now, the old
  # value stays readable as context. Plain text on both sides, because a line
  # never carries Markdown marks. Strike-through only ever meets a value that
  # passed timeline_change_inline?, never a paragraph.
  def timeline_change_pair(change)
    empty = t('views.organisations.tickets.timeline.no_value')
    safe_join([
                tag.span(change.label, class: 'text-cream-700'),
                ' ',
                tag.span(timeline_change_text(change, change.before).presence || empty,
                         class: 'text-cream-500 line-through'),
                ' → ',
                tag.span(timeline_change_text(change, change.after).presence || empty, class: 'text-heading')
              ])
  end

  # The net line of one collapsed run: the RESULT, not the path there
  # (the steps sit in the run's disclosure).
  def timeline_run_line(run, ticket)
    case run.field
    when :subscribers
      t('views.organisations.tickets.timeline.subscribers_changed', names: timeline_run_member_names(run.activities))
    when :assignees
      t('views.organisations.tickets.timeline.assignees_changed', names: timeline_run_member_names(run.activities))
    when :status, :priority, :title
      timeline_changes_line([timeline_run_change(run, run.field, ticket)])
    when :description
      t('views.organisations.tickets.timeline.description_changed_line')
    when :multiple
      timeline_fields_changed_line(timeline_run_changed_fields(run).map { |field| timeline_run_field_label(field, ticket) })
    end
  end

  # The net pairs of a run that its line cannot show - a long title, from the
  # first old value to the last new one. They stand above the steps in the
  # run's disclosure. Only the fields the line names
  # (timeline_run_changed_fields), so a field that ended where it started
  # shows in neither.
  #
  # Deliberate: a long step inside the run only says "Titel geändert", so the
  # middle value of a cascade (the B in A → B → C) is shown nowhere. The run
  # reports its result, the steps report when it happened.
  def timeline_run_details(run, ticket)
    timeline_run_changed_fields(run).filter_map do |field|
      next unless RUN_VALUE_PARAMS.key?(field)

      change = timeline_run_change(run, field, ticket)
      change unless timeline_change_inline?(change)
    end
  end

  # "10:28–10:30" for a run, or the single clock time when the whole run
  # happened within one minute. Range dash, not punctuation.
  def timeline_row_clock_range(run)
    from = run.first_at.in_time_zone
    to = run.created_at.in_time_zone
    text = from.strftime('%H:%M') == to.strftime('%H:%M') ? to.strftime('%H:%M') : "#{from.strftime('%H:%M')}–#{to.strftime('%H:%M')}"
    tag.time(text, datetime: to.iso8601,
                   title: "#{l(from, format: :long)} – #{l(to, format: :long)}")
  end

  private

  # --- Bulk runs ---

  # "4 Tickets geändert", "Sammeländerung an 2 Tickets zurückgenommen": how
  # many tickets and what happened, never the person - the row's second line
  # names them, and Activity#message keeps its full sentence for notifications
  # and mails. What the run changed (or which tickets it deleted) follows after
  # a colon while the whole line stays within INLINE_CHANGE_LIMIT; otherwise it
  # waits in the disclosure. Line and disclosure ask the same question, so the
  # list is always in exactly one of them.
  def timeline_bulk_line(activity)
    timeline_bulk_detail_fits?(activity) ? timeline_bulk_full_line(activity) : timeline_bulk_sentence(activity)
  end

  def timeline_bulk_details(activity)
    return [] if timeline_bulk_detail(activity).nil? || timeline_bulk_detail_fits?(activity)

    label_key = "views.organisations.tickets.timeline.bulk.#{BULK_DETAIL_PARAMS.fetch(activity.action)}_label"
    [Note.new(label: t(label_key), text: timeline_bulk_detail(activity))]
  end

  # THE bulk rule, asked by the line and by the disclosure: the sentence with
  # its detail stays within INLINE_CHANGE_LIMIT. False when there is no detail.
  def timeline_bulk_detail_fits?(activity)
    full = timeline_bulk_full_line(activity)
    full.present? && full.length <= INLINE_CHANGE_LIMIT
  end

  # The sentence with its detail after a colon; nil when the run has none.
  def timeline_bulk_full_line(activity)
    detail = timeline_bulk_detail(activity)
    return if detail.blank?

    t('views.organisations.tickets.timeline.bulk.with_detail', line: timeline_bulk_sentence(activity), detail:)
  end

  def timeline_bulk_sentence(activity)
    params = activity.parameters || {}
    t("views.organisations.tickets.timeline.bulk.#{activity.action.delete_prefix('tickets_bulk_')}",
      count: params['count'].to_i, target: params['target'], source: params['source'])
  end

  # What the run changed, or which tickets it deleted. A delete stores at most
  # ten numbers (ProjectTrackable#track_tickets_bulk_deleted), so the rest is
  # counted ("und 2 weitere") instead of letting ten numbers read as the list.
  def timeline_bulk_detail(activity)
    param = BULK_DETAIL_PARAMS[activity.action]
    detail = param && activity.parameters&.dig(param).presence
    return detail unless detail && param == 'numbers'

    rest = activity.parameters['count'].to_i - detail.split(',').size
    return detail unless rest.positive?

    t('views.organisations.tickets.timeline.bulk.numbers_more', numbers: detail, count: rest)
  end

  # The pairs one activity carries, labelled and with display values: the raw
  # material of the line AND of its disclosure. Empty for activities that
  # carry no pair (an assignment, a comment, a creation).
  def timeline_changes(activity, ticket)
    params = activity.parameters || {}

    case activity.action
    when 'status_changed'
      [timeline_value_change(ticket, 'status', params['from_status'], params['to_status'])]
    when 'priority_changed'
      [timeline_value_change(ticket, 'priority', params['from_priority'], params['to_priority'])]
    when 'title_changed'
      [timeline_name_change(t('views.organisations.tickets.timeline.title_label'),
                            params['from_title'], params['to_title'])]
    when 'moved'
      [timeline_name_change(t('views.organisations.tickets.timeline.project_label'),
                            params['from_project_name'], params['to_project_name'])]
    when 'updated', 'custom_attributes_changed'
      timeline_generic_changes(activity, ticket)
    else
      []
    end
  end

  # One pair that fits stands in the line; otherwise the line names the
  # fields and leaves the pairs to the disclosure.
  def timeline_changes_line(changes)
    return timeline_change_pair(changes.first) if changes.one? && timeline_change_inline?(changes.first)

    timeline_fields_changed_line(changes.map(&:label))
  end

  # "Status, Priorität und Titel geändert" - one grammar for a long single
  # field, for several fields in one save and for a collapsed run.
  def timeline_fields_changed_line(labels)
    t('views.organisations.tickets.timeline.fields_changed_line', fields: labels.to_sentence)
  end

  # The text a reader sees of one value: Markdown source loses its marks and
  # line breaks (Lalabase::SafeMarkdown.plain_text), anything else stays as
  # stored. Blank values read as empty and render as "ohne".
  def timeline_change_text(change, value)
    return '' if value.blank?
    return Lalabase::SafeMarkdown.plain_text(value) if timeline_change_markdown?(change, value)

    value.to_s
  end

  # Label and values from the project's attribute definition, never the raw
  # keys in quotes.
  def timeline_value_change(ticket, attribute_name, raw_old, raw_new)
    definition = timeline_attribute_definition(ticket, attribute_name)
    Change.new(label: definition&.label_for || timeline_field_label(attribute_name),
               before: timeline_display_value(definition, raw_old),
               after: timeline_display_value(definition, raw_new),
               markdown: false)
  end

  def timeline_name_change(label, before, after)
    Change.new(label:, before:, after:, markdown: false)
  end

  def timeline_attribute_definition(ticket, attribute_name)
    ticket&.attribute_definitions&.find { |definition| definition.name == attribute_name }
  end

  def timeline_display_value(definition, raw)
    return if raw.blank?

    definition ? definition.display_value(raw) : raw
  end

  def timeline_secondary_name(activity)
    user = activity.secondary
    user.is_a?(User) ? viewer_display_name(user) : t('activities.deleted_user')
  end

  # Leftover generic updates: every displayable pair becomes a Change. Only a
  # TEXT column holds Markdown source (a ticket's summary, a project's
  # description). A string column holds a name, and a name is never stripped
  # or typeset: a project renamed "1. Entwurf" stays "1. Entwurf" (review
  # finding 11.09.2026, when every column counted as Markdown). Custom
  # attributes carry the project's display values, which are names too.
  def timeline_generic_changes(activity, ticket)
    model = timeline_trackable_class(activity)
    timeline_displayable_changes(activity).map do |name, value|
      before, after = value.is_a?(Array) && value.size == 2 ? value : [nil, value]
      if activity.action == 'custom_attributes_changed'
        timeline_value_change(ticket, name, before, after)
      else
        Change.new(label: timeline_field_label(name, model), before:, after:,
                   markdown: timeline_markdown_column?(model, name))
      end
    end
  end

  def timeline_markdown_column?(model, name)
    model.respond_to?(:columns_hash) && model.columns_hash[name.to_s]&.type == :text
  end

  def timeline_displayable_changes(activity)
    (activity.attribute_changes || {}).except(*Activity::NOISE_CHANGE_ATTRIBUTES)
                                      .reject { |_key, value| value.nil? }
  end

  # A field's display name: the timeline's own words first, then the model's
  # attribute name (activerecord.attributes, "Zusammenfassung" for a ticket's
  # summary). Never the column itself: "Summary" on a German page was the raw
  # name leaking through humanize, which stays only as the last resort.
  def timeline_field_label(name, model = nil)
    default = model ? model.human_attribute_name(name) : name.to_s.humanize
    t("views.organisations.tickets.timeline.fields.#{name}", default:)
  end

  # The trackable's class without loading the record: naming a field needs the
  # model, not the object, so a list of fifty updates costs no query for it.
  # nil when the stored type no longer names a class.
  def timeline_trackable_class(activity)
    activity.association(:trackable).klass
  rescue NameError
    nil
  end

  def timeline_object_type(activity)
    t("views.organisations.tickets.timeline.objects.#{activity.trackable_type.to_s.underscore}",
      default: activity.trackable_type.to_s.humanize)
  end

  # --- Collapsed runs ---

  def timeline_run_steps(run, field)
    run.activities.select { |activity| Activities::RunCollapser::FIELD_FOR_ACTION[activity.action] == field }
       .sort_by(&:created_at)
  end

  # The first old and the last new value of one value field in a run.
  def timeline_run_net_values(run, field)
    from_key, to_key = RUN_VALUE_PARAMS.fetch(field)
    steps = timeline_run_steps(run, field)
    [steps.first.parameters&.dig(from_key), steps.last.parameters&.dig(to_key)]
  end

  def timeline_run_change(run, field, ticket)
    before, after = timeline_run_net_values(run, field)
    return timeline_name_change(t('views.organisations.tickets.timeline.title_label'), before, after) if field == :title

    timeline_value_change(ticket, field.to_s, before, after)
  end

  # The fields a run actually left different. A value field compares its first
  # old with its last new value; a membership field asks whether anybody's
  # state ended different; the description carries no values, so touching it
  # counts. If everything cancelled out, all touched fields are named - the
  # same fallback as the member names below, so the line still says what the
  # cascade was about.
  def timeline_run_changed_fields(run)
    run.fields.select { |field| timeline_run_field_changed?(run, field) }.presence || run.fields
  end

  def timeline_run_field_changed?(run, field)
    if RUN_VALUE_PARAMS.key?(field)
      before, after = timeline_run_net_values(run, field)
      before != after
    elsif %i[assignees subscribers].include?(field)
      timeline_run_member_entries(timeline_run_steps(run, field)).any? { |entry| entry[:first_add] == entry[:last_add] }
    else
      true
    end
  end

  def timeline_run_field_label(field, ticket)
    return timeline_field_label(RUN_FIELD_NAMES.fetch(field)) if RUN_FIELD_NAMES.key?(field)

    timeline_attribute_definition(ticket, field.to_s)&.label_for || timeline_field_label(field)
  end

  # Membership runs (subscribers, assignees): the first step tells us where a
  # person started (removed first = they were in), the last step where they
  # ended. A person added and removed again nets to zero.
  def timeline_run_member_entries(activities)
    by_user = {}
    activities.sort_by(&:created_at).each do |activity|
      add = %w[subscriber_added assigned].include?(activity.action)
      entry = by_user[activity.secondary_id] ||= { first_add: add, user: activity.secondary }
      entry[:last_add] = add
    end
    by_user.values
  end

  # The people whose state actually ENDED different. If everything cancelled
  # out, the touched people are named so the line still says who the cascade
  # was about.
  def timeline_run_member_names(activities)
    entries = timeline_run_member_entries(activities)
    changed = entries.select { |entry| entry[:first_add] == entry[:last_add] }
    changed = entries if changed.empty?
    changed.map { |entry| entry[:user].is_a?(User) ? viewer_display_name(entry[:user]) : t('activities.deleted_user') }
           .join(', ')
  end
end
