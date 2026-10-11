# frozen_string_literal: true

class TimeSessionFilterService
  include ActiveModel::Model
  include ActiveModel::Attributes

  # Define filter parameters as attributes
  attribute :project, default: nil
  attribute :project_id_filter, :string
  attribute :ticket_id, :string
  attribute :meeting_id, :string
  attribute :time_session_group_id, :string
  attribute :creator_id, :string
  attribute :tag_id, :string
  attribute :ticket_phase, :string
  attribute :ticket_status, :string
  # The tickets the reader may open (TicketPolicy::Scope). Not a filter of its
  # own: the ticket phase and status read a ticket's status and may only read
  # these.
  attribute :readable_tickets, default: nil
  attribute :start_date, :string
  attribute :end_date, :string
  attribute :billing_status, :string
  attribute :status_filters # Array<String>: 'billed', 'in_billing', 'without_billing'
  attribute :search, :string
  attribute :smart_folder, default: nil

  def initialize(base_query:, **attributes)
    @base_query = base_query
    super(attributes)
  end

  def call
    query = @base_query

    # Project filter (only when no specific project is selected)
    query = apply_project_filter(query)

    # Subject filter: the two subject ids are separate columns and separate
    # filters, ANDed like everything else here. Setting both is not a mistake to
    # guard against, it is simply a query with no rows -- a booking has one
    # subject or none.
    query = apply_ticket_filter(query)
    query = apply_meeting_filter(query)

    # TimeSessionGroup filter
    query = apply_group_filter(query)

    # Creator filter ("only my sessions" drill-down). Narrows the already
    # policy-scoped base query, so it can never widen visibility.
    query = apply_creator_filter(query)

    # Tag filter: on the booking or on its ticket
    query = apply_tag_filter(query)

    # Ticket phase filter: the phase of the booking's ticket
    query = apply_ticket_phase_filter(query)

    # Ticket status filter: one concrete value of the ticket's status
    query = apply_ticket_status_filter(query)

    # Billing status filter
    query = apply_billing_status_filter(query)

    # Date range filter
    query = apply_date_range_filter(query)

    # Search filter
    apply_search_filter(query)
  end

  private

  def apply_project_filter(query)
    # Only apply when no specific project is selected
    if project.blank? && project_id_filter.present?
      query.where(project_id: project_id_filter)
    else
      query
    end
  end

  def apply_ticket_filter(query)
    return query if ticket_id.blank?

    query.where(ticket_id: ticket_id)
  end

  # The meeting's own filter (S6). Meetings used to be reachable only through a
  # full-text search on their TITLE, which is not a filter but a coincidence:
  # two meetings with the same title both came back, a renamed meeting stopped
  # answering, and a booking whose description merely mentions the title came
  # back too.
  def apply_meeting_filter(query)
    return query if meeting_id.blank?

    query.where(meeting_id: meeting_id)
  end

  def apply_creator_filter(query)
    return query if creator_id.blank?

    query.where(creator_id: creator_id)
  end

  # A booking matches when the tag is on the booking OR on its ticket (step 2
  # of doc/zeiten_weitere_filter_plan.md, variant C). Two IN subqueries and no
  # join: a booking tagged on both sides is still one row, so the count and the
  # sum over the list stay true (the controller's SUM note explains what a
  # duplicated row does to them).
  #
  # Tagging carries no tenant scope of its own. It needs none here: the
  # subqueries only ever narrow the base query, which is scoped already.
  def apply_tag_filter(query)
    return query if tag_id.blank?

    taggings = Tagging.where(tag_id: tag_id)
    on_booking = taggings.where(taggable_type: TimeSession.name).select(:taggable_id)
    on_ticket = taggings.where(taggable_type: Ticket.name).select(:taggable_id)
    table = TimeSession.arel_table

    query.where(table[:id].in(on_booking.arel).or(table[:ticket_id].in(on_ticket.arel)))
  end

  # The phase of the booking's ticket (step 3a of
  # doc/zeiten_weitere_filter_plan.md), read from the status System Functions
  # (TimeSessions::TicketPhase). A booking without a ticket has no phase and
  # drops out (E4). An unknown phase finds no ticket, so the list is empty
  # rather than unfiltered.
  #
  # ⚠️ Only tickets the reader may OPEN count. Seeing one's own time on a ticket
  # is not the right to see the ticket, and "is it done?" is a statement about
  # its status (second review, 29.09.2026). A booking on any other ticket is
  # treated like one without a ticket, and the status definitions are read only
  # from the projects of readable tickets. No readable tickets handed in means
  # none: fail closed.
  #
  # The bookings' tickets come as a subquery through their ids: the query may
  # be distinct and ordered, and a DISTINCT subquery would demand its ORDER BY
  # columns in its select list.
  def apply_ticket_phase_filter(query)
    return query if ticket_phase.blank?

    booked = (readable_tickets || Ticket.none)
             .where(id: TimeSession.where(id: query.reorder(nil).select(:id)).select(:ticket_id))
    tickets = TimeSessions::TicketPhase.tickets(ticket_phase, project_ids: booked.select(:project_id))
    query.where(ticket_id: tickets.where(id: booked.select(:id)).select(:id))
  end

  # One concrete status value of the booking's ticket (step 3b of
  # doc/zeiten_weitere_filter_plan.md), matched EXACTLY on its text.
  # Not through Ticket.with_status_values: that compares a Ruby-downcased value
  # with Postgres LOWER, and the two fold case differently (under
  # LC_CTYPE=C LOWER leaves "Ü" alone), so "Überprüfung", chosen from the menu,
  # found nothing (review of #936). The phases keep that comparison; they
  # match System Function values across projects, a different question.
  #
  # On the TEXT (->>), not by JSON containment: the API accepts an option
  # value that is a JSON number, the menu offers it as "1", and containment
  # asked for the string "1" where the ticket stores the number 1 (second
  # review of #936). As text both are "1", which is also how
  # TimeSessions::TicketStatusValues.find compares, so page and query agree.
  #
  # Offered only for the chosen project's values, but a typed one filters too:
  # it finds what it finds. The same rule as the phase: only tickets the
  # reader may open, none without readable_tickets (fail closed); bookings
  # without such a ticket drop out.
  def apply_ticket_status_filter(query)
    return query if ticket_status.blank?

    tickets = (readable_tickets || Ticket.none).where("tickets.custom_attributes->>'status' = ?", ticket_status)
    query.where(ticket_id: tickets.select(:id))
  end

  def apply_group_filter(query)
    return query if time_session_group_id.blank?

    case time_session_group_id
    when 'ungrouped'
      query.without_group
    when 'grouped'
      query.grouped
    else
      query.by_time_session_group(time_session_group_id)
    end
  end

  def apply_billing_status_filter(query)
    # The new multi-select filter (status_filters[]) takes precedence over the
    # old billing_status. Intersected with the constant HERE, not only at the
    # controller: unknown values are nobody's filter, and a caller handing them
    # through raw must not inherit an unfiltered list. Junk-only falls through
    # to the legacy param below, the same as an absent filter.
    filters = Array(status_filters) & TimeSession::BILLING_STATUS_FILTERS
    if filters.any?
      # Once status_filters is there, it decides, whatever its size. This branch
      # used to be skipped for three states (`filters.size < 3`) and fell through
      # to the legacy billing_status, which turned three lit pills into a filter
      # nobody could see: the pills never clear the legacy key, only an old
      # address carries it (S4 review, 01.09.2026). All three states on is no
      # narrowing at all; the shortcut only spares the WHERE the OR below would
      # build for it.
      return query if (TimeSession::BILLING_STATUS_FILTERS - filters).empty?

      conditions = []
      conditions << '(time_sessions.billed = TRUE)' if filters.include?('billed')
      conditions << '(time_sessions.billed = FALSE AND time_sessions.time_session_group_id IS NOT NULL)' if filters.include?('in_billing')
      conditions << '(time_sessions.billed = FALSE AND time_sessions.time_session_group_id IS NULL)' if filters.include?('without_billing')
      return query.where(conditions.join(' OR '))
    end

    # Legacy: billing_status dropdown ('billed' / 'unbilled')
    case billing_status
    when 'billed'
      query.billed
    when 'unbilled'
      query.unbilled
    else
      query
    end
  end

  def apply_date_range_filter(query)
    start_at = parse_bound(start_date, :beginning_of_day)
    end_at   = parse_bound(end_date, :end_of_day)
    return query if start_at.nil? && end_at.nil?

    if start_at && end_at
      query.where(occurred_on: start_at..end_at)
    elsif start_at
      query.where('occurred_on >= ?', start_at)
    else
      query.where('occurred_on <= ?', end_at)
    end
  end

  def apply_search_filter(query)
    return query if search.blank?

    term = search.strip
    search_term = "%#{term}%"

    # Search the description, BOTH subject titles (ticket OR meeting, Gespräche
    # Slice 2) and the billing's name, so a session is findable by any of the
    # things a reader can see about it -- not only by its own description.
    # left_joins keeps subject-less and billing-less sessions matchable too.
    query = query.left_joins(:ticket, :meeting, :time_session_group).distinct

    conditions = ['time_sessions.description ILIKE :q',
                  'tickets.title ILIKE :q',
                  'meetings.title ILIKE :q',
                  'time_session_groups.name ILIKE :q']
    binds = { q: search_term }

    # ⚠️ The ticket NUMBER, matched exactly, not as a substring. People refer to a
    # ticket as "89" or "#89", and a LIKE on the cast number would answer that
    # with 89, 189, 890 and 8912 -- an answer that looks like a search result and
    # is not one. A number is not text, so it is asked as a number.
    number = term.delete_prefix('#')
    if number.match?(/\A\d+\z/)
      conditions << 'tickets.number = :n'
      binds[:n] = number.to_i
    end

    query.where(conditions.join(' OR '), **binds)
  end

  # Parse a YYYY-MM-DD bound into an INCLUSIVE Time in the app zone: the start from
  # 00:00 (:beginning_of_day), the end THROUGH 23:59:59 (:end_of_day). Without the
  # end_of_day a date-typed end bound casts to midnight and silently drops every
  # session that occurred on the end date itself.
  def parse_bound(date_string, edge)
    return nil if date_string.blank?

    Time.zone.parse(date_string.to_s)&.public_send(edge)
  rescue ArgumentError, TypeError
    Rails.logger.warn "TimeSessionFilterService: Invalid date format: #{date_string}"
    nil
  end
end
