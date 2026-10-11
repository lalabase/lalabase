# frozen_string_literal: true

# Does the event stream still agree with the live seat count? (M0b/M0c,
# doc/abrechnungsmodell_plan.md §3.)
#
# Entry point: call
#
# This is the acceptance test of the backfill and, run repeatedly, the guard
# against later drift. The plan is explicit about why the second part matters:
# a one-off check at backfill time proves nothing about tomorrow, and there is
# a known hole waiting. A flip of Role#billable changes the counted state of
# every membership on that role WITHOUT touching a membership, so no callback
# fires and no event is written. The flag has no UI today, which is the only
# reason the hole is shut, and the guest-role work that opens it is a
# precondition for the first paying customer.
#
# Drift is reported, never repaired. A repair would have to invent a moment at
# which the change happened, and inventing timestamps in an append-only billing
# ledger is how a wrong number becomes an authoritative one.
#
# TWO KINDS of finding, and keeping them apart is what makes a nightly run
# usable. Before the opening backfill has run, EVERY pre-existing account
# reconstructs to zero, so a single undifferentiated list would report nine
# accounts as "drifting" every night, and an alarm that fires every night is an
# alarm nobody reads. `:not_reconstructible` says the stream has no basis for
# this account at all; `:mismatch` says it has one and the numbers disagree.
# Both are problems, but only the second one is a defect in the data.
module Subscriptions
  class SeatStreamDrift
    KIND_MISMATCH = :mismatch
    KIND_NOT_RECONSTRUCTIBLE = :not_reconstructible
    KIND_FAILED = :failed

    Finding = Struct.new(:account, :kind, :live, :from_stream, :error, keyword_init: true) do
      # Stream minus live: POSITIVE means the stream counts too many, which is
      # the too-high invoice. Pinned in that direction on purpose, so a reader
      # never has to guess which side to go looking on.
      #
      # nil when there is no stream figure to compare against. A 0 there would be
      # a number nobody measured, and -2 would read as "the stream is two short"
      # when the truth is "nobody looked".
      def difference
        return nil if from_stream.nil?

        from_stream - live
      end

      def not_reconstructible?
        kind == KIND_NOT_RECONSTRUCTIBLE
      end

      def failed?
        kind == KIND_FAILED
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(at: Time.current)
      @at = at
    end

    # Returns only the accounts with a finding. An empty array is the pass.
    def call
      # Hoisted: one global marker for the whole sweep, read once rather than
      # once per account.
      opened_at = SystemSetting.seat_stream_opened_at

      ::Account.includes(:organisations).find_each.filter_map do |account|
        drift_finding_for_account(account, opened_at)
      end
    end

    private

    # One broken account must not take the sweep down with it. SeatCounter raises
    # loudly on purpose (D7), which is right for a request and wrong for the
    # nightly watchman: the alarm whose entire value is its log line would produce
    # NO line at all, for every account, because of one. So the failure becomes a
    # finding of its own and the sweep goes on.
    def drift_finding_for_account(account, opened_at)
      classify_account(account, opened_at)
    rescue StandardError => e
      Finding.new(account: account, kind: KIND_FAILED, live: nil, from_stream: nil,
                  error: "#{e.class}: #{e.message}")
    end

    def classify_account(account, opened_at)
      live = SeatCounter.new(account).call

      # Asked BEFORE comparing, and asked about @at rather than about now: for a
      # moment BEFORE the stream became complete the reconstruction is empty by
      # construction. Reporting that as a mismatch would blame the data for a gap
      # the plan says must be named as a gap (§3).
      from = SeatEvent.reconstructible_from(account, opened_at: opened_at)
      if from.nil? || @at < from
        return Finding.new(account: account, kind: KIND_NOT_RECONSTRUCTIBLE,
                           live: live, from_stream: nil)
      end

      from_stream = SeatEvent.counted_user_ids_for(account: account, at: @at).size
      return if live == from_stream

      Finding.new(account: account, kind: KIND_MISMATCH, live: live, from_stream: from_stream)
    end
  end
end
