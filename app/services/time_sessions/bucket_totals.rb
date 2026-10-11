# frozen_string_literal: true

# Sums a time-session relation into the three billing buckets, in ONE query.
#
# Entry point: call
#
# Extracted from Lalabase::Tools::SummarizeTimeSessions (S3c T3) when the
# assistant's artefact lane became a second reader of the same numbers. The
# classification itself still belongs to TimeSession.billing_bucket_for; what
# lives here is the aggregation around it, so the chat answer and the report
# panel beside it can never drift into two different totals for one question.
#
# The relation is expected to be NARROWED already (TimeSessions::ViewingScope,
# filters). This object counts what it is given and asks no rights questions.
module TimeSessions
  class BucketTotals
    def self.call(scope:)
      new(scope: scope).call
    end

    def self.empty
      TimeSession::BILLING_STATUS_FILTERS.index_with { { minutes: 0, sessions: 0 } }
    end

    def initialize(scope:)
      @scope = scope
    end

    # => { 'billed' => { minutes:, sessions: }, 'in_billing' => …, 'without_billing' => … }
    #
    # Always all three keys, zeroed when a bucket is empty: a caller that reads
    # totals['billed'] must not have to know whether the query happened to return
    # that row. unscope(:order) because an ORDER BY on a grouped query is either
    # a Postgres error or dead weight.
    def call
      totals = self.class.empty
      rows.each do |billed, grouped, minutes, sessions|
        bucket = TimeSession.billing_bucket_for(billed: billed, grouped: grouped)
        totals[bucket][:minutes] += minutes.to_i
        totals[bucket][:sessions] += sessions.to_i
      end
      totals
    end

    private

    def rows
      @scope.unscope(:order)
            .group(:billed, Arel.sql('time_session_group_id IS NOT NULL'))
            .pluck(:billed, Arel.sql('time_session_group_id IS NOT NULL'), Arel.sql('SUM(duration)'),
                   Arel.sql('COUNT(*)'))
    end
  end
end
