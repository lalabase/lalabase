# frozen_string_literal: true

# Folds a subject's per-session billing buckets into ONE word for display.
#
# Entry point: call
#
# A ticket or meeting can hold sessions in several buckets at the same time, so
# every surface that labels the SUBJECT (the hours chip in the ticket header via
# SubjectTimeSummaryService, the billing column of the ticket table via
# TimeSessions::SubjectTotals) has to answer "and what does that make the whole
# ticket?". That fold lives here once; the per-session classification it builds
# on stays with TimeSession.billing_bucket_for.
#
# Vocabulary: ONE set of names. A subject-level answer is a bucket of
# TimeSession::BILLING_STATUS_FILTERS as a symbol, plus :mixed and :no_sessions
# for the two answers a single session cannot give. Until S1 this class
# translated 'without_billing' into :open through a BUCKET_TO_STATUS map, which
# was the second of the nine names the same three states carried; the map is
# gone with the name. The words themselves live once at
# views.time_sessions.billing_status.*, rendered through
# TimeSessionsHelper#time_billing_state_label.
module TimeSessions
  class SubjectBillingStatus
    # counts: { 'billed' => n, 'in_billing' => n, 'without_billing' => n },
    # missing keys count as zero. Returns :no_sessions, :mixed or one of the
    # buckets as a symbol.
    # How far a subject has got, as a whole number: the share of its MINUTES that
    # is invoiced. nil when nothing is, so a caller has nothing to print.
    #
    # Lives beside the fold on purpose. The word and the number answer the same
    # question at two resolutions, and the word must never be derived from the
    # number: 999 of 1000 minutes rounds to 100 and is still mixed.
    def self.percent_billed(minutes:)
      total = minutes.values.sum(&:to_i)
      billed = minutes['billed'].to_i
      return nil if total.zero? || billed.zero?

      ((billed.to_f / total) * 100).round
    end

    def self.call(counts:)
      # Iterating the constant, not the hash: an unknown key in counts is not a
      # fourth state, and the answer stays in the canonical order.
      present = TimeSession::BILLING_STATUS_FILTERS.select { |bucket| counts[bucket].to_i.positive? }

      return :no_sessions if present.empty?
      return :mixed if present.size > 1

      present.first.to_sym
    end
  end
end
