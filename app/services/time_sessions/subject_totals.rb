# frozen_string_literal: true

# Booked minutes and combined billing status per SUBJECT (ticket), for a whole
# page of tickets in ONE query.
#
# Entry point: call
#
# The ticket table's two time columns need per row what SubjectTimeSummaryService
# answers for a single ticket. Calling that service per row costs two queries and
# a permission lookup each, on the busiest list in the app. This object asks the
# same question for many subjects at once and hands back a lookup.
#
# The relation is expected to be NARROWED already (TimeSessions::ViewingScope), the
# same contract as TimeSessions::BucketTotals: this object counts what it is given
# and asks no rights questions.
#
# Reads the SESSION's billed flag, not its group's — the same fact
# TimeSessionFilterService#apply_billing_status_filter filters on, so the number in
# a cell and the list its link opens can never describe different sets.
module TimeSessions
  class SubjectTotals
    def self.call(scope:, ticket_ids:)
      new(scope: scope, ticket_ids: ticket_ids).call
    end

    # The entry every caller gets for a ticket with nothing booked. Handed out so a
    # view can render a row without asking whether the query returned that ticket.
    # All three keys, always: a view drawing a bar must not have to ask whether a
    # bucket happened to be in the result.
    def self.blank_shares
      TimeSession::BILLING_STATUS_FILTERS.index_with { 0 }
    end

    def self.empty_entry
      { minutes: 0, sessions: 0, shares: blank_shares, billing_status: :no_sessions, percent: nil }
    end

    def initialize(scope:, ticket_ids:)
      @scope = scope
      @ticket_ids = Array(ticket_ids).compact.uniq
    end

    # => { ticket_id => { minutes:, sessions:, billing_status: } }
    #
    # Always one entry per requested id, zeroed when nothing is booked: a view that
    # reads totals[ticket.id] must not have to nil-check.
    def call
      return {} if @ticket_ids.empty?

      counts = @ticket_ids.index_with { blank_counts }

      rows.each do |ticket_id, billed, grouped, minutes, sessions|
        bucket = TimeSession.billing_bucket_for(billed: billed, grouped: grouped)
        entry = counts[ticket_id]
        next unless entry

        entry[:minutes] += minutes.to_i
        entry[:sessions] += sessions.to_i
        entry[:buckets][bucket] += sessions.to_i
        # The minutes per bucket were selected all along and thrown away here.
        # The billing column draws the same share bar as the time list (plan §4),
        # and it needs them.
        entry[:shares][bucket] += minutes.to_i
      end

      counts.transform_values { |entry| finalize(entry) }
    end

    private

    def blank_counts
      { minutes: 0, sessions: 0, buckets: Hash.new(0), shares: self.class.blank_shares }
    end

    def finalize(entry)
      shares = self.class.blank_shares.merge(entry[:shares])
      {
        minutes: entry[:minutes],
        sessions: entry[:sessions],
        shares: shares,
        billing_status: SubjectBillingStatus.call(counts: entry[:buckets]),
        percent: SubjectBillingStatus.percent_billed(minutes: shares)
      }
    end

    # unscope(:order) because an ORDER BY on a grouped query is either a Postgres
    # error or dead weight (same reason as BucketTotals).
    def rows
      @scope.where(ticket_id: @ticket_ids)
            .unscope(:order)
            .group(:ticket_id, :billed, Arel.sql('time_session_group_id IS NOT NULL'))
            .pluck(:ticket_id, :billed, Arel.sql('time_session_group_id IS NOT NULL'),
                   Arel.sql('SUM(duration)'), Arel.sql('COUNT(*)'))
    end
  end
end
