# frozen_string_literal: true

# The three levels of the Projektzeiten table, built from ONE page of bookings:
#
#   Monat                      sum of the rows below it, shared billing account
#     Bezug in diesem Monat    minutes, share bar, state, account,
#                              "06:40 von 13:40 · 07:00 ausgeblendet"
#       Zeit                   the single bookings, shown when the row is open
#
# Entry point: call
#
# A ROW is a subject in a project in a month, not a subject: ticket #85 stands
# once under August and once under July, with different sums. Its key is a
# GROUPING and never a target -- it replaces no id and goes into no form.
#
# This object asks NO rights questions, the same contract as
# TimeSessions::BucketTotals: `sessions` and `visible_scope` arrive narrowed
# (policy_scope). That contract carries the most weight for the hidden minutes,
# which are read from `visible_scope`: taken from an unnarrowed relation, the
# sentence "06:40 von 13:40" tells a user who may only see their own hours
# exactly how much a colleague booked on that ticket.
#
# S1 of doc/projektzeiten_tabelle_plan.md.
module TimeSessions
  class ListRows
    # visible_scope: every booking the viewer may see, WITHOUT the page's filters
    #                and without the smart folder. The denominator of "x von y".
    # sessions:      the loaded bookings of this page, each carrying `month_key`
    #                (see .month_key_sql) and its associations preloaded.
    # page_keys:     [project_id, ticket_id, meeting_id, month] per row, already
    #                in the order the page shows them.
    def self.call(visible_scope:, sessions:, page_keys:)
      new(visible_scope: visible_scope, sessions: sessions, page_keys: page_keys).call
    end

    # The month key, computed by the DATABASE in the application's zone, so that
    # the grouping and the period filter (TimeSessionFilterService, which bounds
    # on Time.zone days) draw the same line. `occurred_on` is stored naive in
    # UTC: it is read as UTC first and only then moved into the zone. Truncating
    # without that step files a booking made at 00:30 in Berlin under the
    # previous month, and nothing on the screen says so.
    #
    # ONE expression, used by both queries in S2 and by the grouping here.
    def self.month_key_sql
      ActiveRecord::Base.sanitize_sql_array(
        ["date_trunc('month', time_sessions.occurred_on AT TIME ZONE 'UTC' AT TIME ZONE ?)::date",
         Time.zone.tzinfo.name]
      )
    end

    # Narrows a relation to (roughly) the rows of ONE page: their projects, their
    # month window, their subjects. Coarse on purpose. A tuple IN-list cannot
    # match NULL and a row without a subject carries two of them, so callers drop
    # the surplus by key afterwards.
    #
    # S2's second query (the bookings of the page) and the hidden-minute total
    # below both go through here: they have to agree on what "these rows" means,
    # or the numerator and the denominator of "x von y" describe two sets.
    def self.narrow_to(relation, page_keys)
      return relation.none if page_keys.empty?

      scoped = relation.where(project_id: page_keys.map(&:first).uniq)
                       .where(occurred_on: month_window_for(page_keys))
      clause = subject_clause_for(page_keys)
      clause ? scoped.merge(clause) : scoped
    end

    def self.month_window_for(page_keys)
      months = page_keys.map(&:last)
      first = months.min
      last = months.max

      Time.zone.local(first.year, first.month, 1)...Time.zone.local(last.year, last.month, 1).next_month
    end
    private_class_method :month_window_for

    # `ticket_id = NULL` matches nothing in SQL, so the subject-less rows need
    # their own IS NULL branch or their "von y" would come back empty.
    def self.subject_clause_for(page_keys)
      ticket_ids = page_keys.filter_map { |key| key[1] }.uniq
      meeting_ids = page_keys.filter_map { |key| key[2] }.uniq
      subjectless = page_keys.any? { |key| key[1].nil? && key[2].nil? }

      clause = nil
      clause = or_merge(clause, TimeSession.where(ticket_id: ticket_ids)) if ticket_ids.any?
      clause = or_merge(clause, TimeSession.where(meeting_id: meeting_ids)) if meeting_ids.any?
      clause = or_merge(clause, TimeSession.where(ticket_id: nil, meeting_id: nil)) if subjectless
      clause
    end
    private_class_method :subject_clause_for

    def self.or_merge(left, right)
      left.nil? ? right : left.or(right)
    end
    private_class_method :or_merge

    def initialize(visible_scope:, sessions:, page_keys:)
      @visible_scope = visible_scope
      @sessions = sessions
      @page_keys = page_keys
    end

    def call
      return [] if @page_keys.empty? || @sessions.empty?

      ensure_month_key!

      rows = @page_keys.filter_map { |key| build_row(key) }
      # page_keys arrives sorted by month first, so grouping keeps that order.
      rows.group_by { |row| row[:key].last }.map { |month, month_rows| build_month(month, month_rows) }
    end

    private

    def ensure_month_key!
      return if @sessions.first.has_attribute?(:month_key)

      raise ArgumentError, 'sessions must carry month_key -- select TimeSessions::ListRows.month_key_sql'
    end

    def build_month(month, month_rows)
      {
        month: month,
        label: I18n.l(month, format: :month_year),
        sum_minutes: month_rows.sum { |row| row[:minutes] },
        rows: month_rows
      }
    end

    def build_row(key)
      row_sessions = sessions_by_key[key]
      return nil if row_sessions.blank?

      minutes, counts = buckets_of(row_sessions)
      booked = row_sessions.sum { |session| session.duration.to_i }
      # max() rather than a bare subtraction: a total below the visible sum would
      # mean the page shows something the unfiltered scope does not, and a
      # negative "ausgeblendet" would put that contradiction on the screen.
      total = [total_minutes.fetch(key, booked), booked].max
      first = row_sessions.first

      {
        key: key,
        project: first.project,
        subject: first.ticket || first.meeting,
        minutes: booked,
        shares: minutes,
        state: SubjectBillingStatus.call(counts: counts),
        percent: SubjectBillingStatus.percent_billed(minutes: minutes),
        hidden_minutes: total - booked,
        total_minutes: total,
        sessions: row_sessions
      }
    end

    # Minutes AND session counts in ONE pass. The bar needs the minutes, the word
    # is folded from the counts by SubjectBillingStatus (the owner the hours chip
    # and the ticket column already read); walking the list twice would be two
    # chances to classify the same booking differently.
    def buckets_of(list)
      minutes = TimeSession::BILLING_STATUS_FILTERS.index_with { 0 }
      counts  = TimeSession::BILLING_STATUS_FILTERS.index_with { 0 }

      list.each do |session|
        bucket = TimeSession.billing_bucket_for(
          billed: session.billed?, grouped: session.time_session_group_id.present?
        )
        minutes[bucket] += session.duration.to_i
        counts[bucket] += 1
      end

      [minutes, counts]
    end

    def sessions_by_key
      @sessions_by_key ||= @sessions.group_by do |session|
        [session.project_id, session.ticket_id, session.meeting_id, session.month_key]
      end
    end

    # ONE query for the whole page: how many minutes each row holds when NO
    # filter applies. The surplus the coarse narrowing brings along is dropped by
    # the #fetch in build_row.
    def total_minutes
      @total_minutes ||= begin
        month_sql = Arel.sql(self.class.month_key_sql)

        self.class.narrow_to(@visible_scope.unscope(:order), @page_keys)
            .group(:project_id, :ticket_id, :meeting_id, month_sql)
            .pluck(:project_id, :ticket_id, :meeting_id, month_sql, Arel.sql('SUM(duration)'))
            .to_h { |project_id, ticket_id, meeting_id, month, minutes| [[project_id, ticket_id, meeting_id, month], minutes.to_i] }
      end
    end
  end
end
