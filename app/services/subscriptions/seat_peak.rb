# frozen_string_literal: true

# The peak of simultaneously occupied, DEDUPLICATED seats of one account in one
# measurement month, cut into SECTIONS at ownership boundaries (M2 + M3,
# doc/abrechnungsmodell_plan.md A2/A3/A9 and §4), together with the breakdown §5
# requires: per section the peak, when it was reached, which organisations were
# part of it, and how many days of the month the section covers.
#
# Entry point: call
#
# WHY A REPLAY and not a plus/minus counter. §4 spells it out: because a user is
# deduplicated across the account's organisations (D4.1), removing them from
# organisation 1 frees no seat while they still sit in organisation 2 of the
# same account. A counter gets that silently wrong, and the wrong result looks
# entirely plausible. The map of occupied PAIRS is correctness, not convenience.
#
# WHY SECTIONS AT ALL (A3). Only two things split a month, and both are rare and
# deliberate: an organisation moving to another account, and the start of the
# billing relationship. Without the first cut, the losing and the gaining account
# would each hold the same people for the whole month and both would be invoiced
# for them. Without the second, a customer starting on the 28th would pay a full
# month or the answer would be a matter of opinion.
#
# THERE IS NO MONTH PEAK once a month is split, and that is why this result has
# no `peak` of its own. A9 decided that each section computes with its own tier;
# a single figure spanning both sections would be a number that never existed.
# An ordinary month has exactly one section and reads as before.
#
# READS, never writes. The month's opening state comes from the SeatSnapshot the
# M1 writer laid down; a missing snapshot is reported as `unavailable`, never
# computed here on the fly. A second writer would make a broken monthly job
# invisible: the peak would keep answering while the boundary table quietly
# rotted, and the gap watcher is the only thing that would ever have noticed.
#
# NOT PERSISTED either, which is the same decision from the other side. Both
# inputs are permanent (seat_events is append-only, the snapshot is
# recomputable), so this figure is reproducible at any time. A third table would
# need its own staleness rule; freezing the number is the invoice's job, at the
# moment the invoice is written.
#
# NO TIER AND NO MONEY. §5 also names the tier and the amount, and both need the
# price ladder that §8 keeps out of this plan -- plus the answer depends on the
# billing interval, which is M4. A section carries `share`; whoever prices it
# multiplies through Subscriptions::PriceLookup.
module Subscriptions
  class SeatPeak
    STATUS_OK = :ok
    STATUS_NOT_RECONSTRUCTIBLE = :not_reconstructible
    STATUS_UNAVAILABLE = :unavailable
    # The month lies entirely before the account's billing start. Measurable,
    # deliberately outside the billing relationship, so there is nothing to cut
    # into sections. Its own status rather than an empty ok, because "no answer"
    # and "answer: nothing" ask a human for different things.
    STATUS_NOT_BILLABLE = :not_billable

    # Why there is no answer. Only ever set together with STATUS_UNAVAILABLE,
    # and the three are kept apart because each one asks for something
    # different: wait, run the job, or investigate the failure.
    REASON_MONTH_NOT_STARTED = :month_not_started
    REASON_SNAPSHOT_MISSING = :snapshot_missing
    REASON_SNAPSHOT_FAILED = :snapshot_failed

    # ONE stretch of the month under one ownership arrangement.
    #
    # TWO different cuts live here, and confusing them is the trap this comment
    # exists for. `measured_from`/`measured_to` are the exact instants the peak
    # was measured over; `first_day`/`last_day` are the calendar days the section
    # is BILLED for. They disagree by design on a move day.
    #
    # A3's own worked example is the evidence. A move at 10:00 on the 10th, and
    # the losing account goes from 6 seats to 4:
    #
    #     1.-9.    peak 6
    #     10.-31.  peak 4
    #
    # For the second section to read 4 and not 6, the measurement has to start at
    # the MOVE MOMENT -- between midnight and 10:00 the account still held all
    # six. Cutting the measurement at midnight would put those six into the
    # second section too, and both accounts would carry the same people for the
    # move day, which is the exact thing A3 exists to prevent.
    #
    # The DAYS are calendar days and the move day belongs to the new section
    # (A6), and A6 says why: it makes the daylight-saving switch meaningless and
    # the invoice readable. The cost is at most one day's share.
    Section = Struct.new(:measured_from, :measured_to, :first_day, :last_day, :month_days,
                         :peak, :peak_at, :pairs_at_peak, keyword_init: true) do
      # Zero when a cut lands on the section's own first day -- a move at 10:00
      # on the 1st gives the outgoing arrangement ten measured hours and no
      # billed day. The section is still reported: its peak was real, and
      # dropping it would make a measured stretch of the month disappear without
      # a trace. An invoice writer skips zero-day lines.
      def days
        [(last_day - first_day).to_i + 1, 0].max
      end

      # Rational, not a Float, and the honest reason is narrower than it looks.
      # Array#sum compensates float error (Kahan), so "the sections add up to one
      # month" holds either way -- measured, the Float variant passed that
      # example. What a Float really breaks is the breakdown the operator reads:
      # the rake output prints numerator and denominator ("19/31 des Monats"),
      # and a Float answers those with astronomical integers. The second reason
      # is unpinned today and named as such: an amount derived from a Float share
      # can land a cent away from one derived exactly, and that becomes real with
      # the first invoice.
      def share
        Rational(days, month_days)
      end

      def billed?
        days.positive?
      end

      # A section covering every day of the month. NOT the same as "the only
      # section": a billing start on the 28th makes ONE section of four days,
      # and a cut on the 1st makes two of which the second IS whole. Both cases
      # got this wrong when the display hung on the section COUNT instead
      # (review finding on #533: the first month of every customer looked like a
      # full one on the admin page).
      def whole_month?
        days == month_days
      end

      # Who was part of the peak (§5).
      #
      # CAUTION: `seats` sums to MORE than `peak` as soon as one user sits in
      # two organisations of this account. That is D4.1 working, not an error,
      # and `shared_seats` names the difference -- so a support answer can state
      # it up front instead of leaving the customer to find a contradiction.
      #
      # Grouped by the ID ALONE, never by (id, name). organisation_name is
      # frozen per event, so one organisation renamed mid-month carries the old
      # name on whoever was already there and the new one on whoever joined
      # after. Keyed by the pair, that showed ONE organisation as two rows with
      # the same UUID -- the peak stayed right and the breakdown became the
      # contradiction §5 exists to prevent (measured, review finding on #529).
      def organisations
        pairs_at_peak.group_by { |pair| pair['organisation_id'] }
                     .map { |id, entries| organisation_entry(id, entries) }
                     .sort_by { |entry| [-entry['seats'], entry['organisation_name'].to_s] }
      end

      # How many of the per-organisation seats above are the same person twice.
      # Zero for the ordinary single-organisation account.
      def shared_seats
        organisations.sum { |entry| entry['seats'] } - peak
      end

      private

      # The LAST entry's name wins where an organisation offers several. After a
      # mid-month rename that is normally the newcomer whose event carries the
      # new name, because a rising peak ends on a freshly added pair.
      #
      # BEST EFFORT, not a guarantee, and deliberately not more: making it exact
      # would mean ordering the pairs by their last write, and no example could
      # be built that tells the two apart (the mutation probe stayed green, so
      # the reordering came back out). What IS guaranteed is the row count: one
      # organisation is one line, whatever it is called.
      def organisation_entry(id, entries)
        { 'organisation_id' => id, 'organisation_name' => entries.last['organisation_name'],
          'seats' => entries.map { |entry| entry['user_id'] }.uniq.size }
      end
    end

    # `sections` is empty unless the status is ok. NOT a zero peak: §3 forbids
    # answering an unmeasurable period with a number, and a 0 would travel
    # straight onto an invoice as "no seats" instead of "nobody could look".
    Result = Struct.new(:account, :period_start, :status, :reason, :sections, :snapshot,
                        :window_start, :window_end, keyword_init: true) do
      def ok?
        status == STATUS_OK
      end

      def not_reconstructible?
        status == STATUS_NOT_RECONSTRUCTIBLE
      end

      def unavailable?
        status == STATUS_UNAVAILABLE
      end

      def not_billable?
        status == STATUS_NOT_BILLABLE
      end

      # More than one arrangement in this month, so there is no single peak to
      # quote and every consumer has to show the sections.
      def split?
        sections.size > 1
      end

      # Does this section need its span and its share spelled out? THE one
      # answer, because the admin page and the rake breakdown both ask it and
      # two hand-written versions drifted apart once already.
      #
      # Not simply `split?`: a lone section can cover four days of the month
      # (a billing start on the 28th). Not simply `!whole_month?` either: in a
      # month cut on the 1st the second section runs all 31 days, and labelling
      # only its zero-day sibling would read as a rendering error.
      def detailed?(section)
        split? || !section.whole_month?
      end

      # The running month can still grow a higher peak, so its figures are an
      # interim reading rather than a result. Named because the difference is
      # invisible in the numbers themselves, and putting an interim figure on an
      # invoice is precisely the mistake this flag exists to prevent.
      def provisional?
        ok? && window_end > Time.current
      end

      # THE one mapping from "nothing to show" to a reason, so the admin page and
      # the rake task cannot drift into two different explanations of the same
      # state. nil when there ARE sections. The two non-unavailable statuses are
      # folded in as reasons of their own: they are separate STATUSES because a
      # caller must tell "never answerable" from "not answered yet" from
      # "deliberately outside the billing relationship", but to a human reading
      # the screen they are simply further things that can be the case.
      def reason_key
        return nil if ok?
        return status if not_reconstructible? || not_billable?

        reason
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # period_start is normalised to the month's first day, same as the writer, so
    # a mid-month date names the month it lies in rather than starting a second
    # grid of boundaries. Through SeatSnapshot, because a bare `.to_date` on a
    # Time answers the previous month for the first two hours of every month
    # (the app runs on UTC, the months are Berlin).
    def initialize(account:, period_start:)
      @account = account
      @period_start = SeatSnapshot.normalise_period(period_start)
    end

    # A month that has not begun gets an ANSWER here, where the writer RAISES for
    # the same instant (SeatSnapshotWriter#refuse_future_boundary!). Not an
    # inconsistency: writing a row for a boundary that has not happened would
    # corrupt the boundary table, while asking about it is an ordinary question
    # whose answer is "not yet". Raising would turn a click on the wrong month in
    # the admin backend into a 500.
    def call
      return answer(STATUS_UNAVAILABLE, reason: REASON_MONTH_NOT_STARTED) if window_start > Time.current
      return answer(STATUS_NOT_BILLABLE) if before_billing_start?

      snapshot = boundary_snapshot
      return answer(STATUS_UNAVAILABLE, reason: REASON_SNAPSHOT_MISSING) if snapshot.nil?
      return answer(STATUS_NOT_RECONSTRUCTIBLE, snapshot: snapshot) if snapshot.not_reconstructible?
      return answer(STATUS_UNAVAILABLE, reason: REASON_SNAPSHOT_FAILED, snapshot: snapshot) if snapshot.failed?

      replay(snapshot)
    end

    private

    # Its own method rather than a line inside #call, so the per-account query it
    # issues has a NAME in the stack. The Prosopite allowlist matches stack
    # frames, and an entry for `call` would silence half the codebase.
    def boundary_snapshot
      SeatSnapshot.find_by(account: @account, period_start: @period_start)
    end

    def replay(snapshot)
      occupied = opening_state(snapshot)
      blocks = simultaneous_blocks

      # Everything before the first section start shapes the state but belongs to
      # no billed stretch: a customer whose billing begins on the 28th is not
      # invoiced for the 27th, and the peak of those days must not leak into the
      # section that IS invoiced.
      before, blocks = split_at(blocks, section_starts.first)
      before.each { |block| block.each { |event| apply(occupied, event) } }

      sections = section_starts.each_with_index.map do |from, index|
        to = section_starts[index + 1] || window_end
        mine, blocks = split_at(blocks, to)
        # `occupied` is carried, not rebuilt: a section opens on exactly the
        # state its predecessor ended in.
        measure_section(from: from, to: to, occupied: occupied, blocks: mine)
      end

      answer(STATUS_OK, snapshot: snapshot, sections: sections)
    end

    # Ordered input, so the split keeps both halves ordered. Not `partition`
    # with a stored index: the blocks are consumed section by section and a
    # leftover array reads better than an offset nobody can see.
    def split_at(blocks, moment)
      blocks.partition { |block| block.first.occurred_at < moment }
    end

    def measure_section(from:, to:, occupied:, blocks:)
      # A7 AT THE SECTION EDGE, and it is load-bearing rather than tidy.
      # Everything happening exactly at the cut belongs to the arrangement that
      # STARTS there, so it is applied before the section is first measured.
      #
      # Measured the other way round, the opening reading is the state the cut
      # ended: for the account losing an organisation that is still the full
      # pre-move count, the peak of the second section never drops below it, and
      # the split buys nothing. Measured: the old account answered [2, 2] where
      # the truth is [2, 0].
      at_cut, blocks = blocks.partition { |block| block.first.occurred_at == from }
      at_cut.each { |block| block.each { |event| apply(occupied, event) } }

      peak = measure(occupied)
      peak_at = from
      pairs_at_peak = occupied.values

      blocks.each do |block|
        block.each { |event| apply(occupied, event) }

        count = measure(occupied)
        next unless count > peak

        peak = count
        peak_at = block.first.occurred_at
        pairs_at_peak = occupied.values
      end

      build_section(from: from, to: to, peak: peak, peak_at: peak_at, pairs_at_peak: pairs_at_peak)
    end

    # The day allocation (A6): calendar days in Europe/Berlin, and the day a cut
    # falls on belongs to the section that STARTS there. `to` is the next cut or
    # the month boundary, so the previous section ends the day before it -- and
    # the final section ends on the last day of the month, never on the 1st of
    # the next, which is what boundary_moment(next_month) would otherwise say.
    def build_section(from:, to:, peak:, peak_at:, pairs_at_peak:)
      last_day = to == window_end ? @period_start.end_of_month : local_date(to) - 1
      Section.new(measured_from: from, measured_to: to,
                  first_day: local_date(from), last_day: last_day,
                  month_days: @period_start.end_of_month.day,
                  peak: peak, peak_at: peak_at, pairs_at_peak: pairs_at_peak)
    end

    def local_date(moment)
      moment.in_time_zone(Constants::BILLING_TIME_ZONE).to_date
    end

    # Pure date arithmetic, and asked BEFORE the snapshot on purpose. Such a
    # month usually has no snapshot either, and answering "no boundary written
    # yet" would send an operator off to run a backfill for a month that will
    # never be invoiced. Both statements are true; this one is terminal, the
    # other is not (review finding on #533).
    def before_billing_start?
      billing_start_moment >= window_end
    end

    # Where the month is cut, ascending, the first entry being where measuring
    # starts. Never empty -- #call has already refused a month that lies
    # entirely before the billing start.
    #
    # Sorted rather than trusted: move_moments comes out of an already
    # chronological relation, so this changes nothing today (the mutation probe
    # stayed green) -- it keeps the ordering the sections depend on local instead
    # of resting on a scope two files away. No `uniq`: a move writes one
    # timestamp for all its pairs and move_moments already dedupes it, and a move
    # landing exactly on the start is excluded by the strict comparison.
    def section_starts
      @section_starts ||=
        ([billing_start_moment] +
         move_moments.select { |moment| moment > billing_start_moment }).sort
    end

    # Midnight Berlin of the start date, or the month boundary when billing began
    # before this month. A nil start does NOT mean "never pays": under R1 it
    # means "undecided", and deciding whether an account may be invoiced is
    # Subscriptions::BillingList's job (three sections, one of them explicitly
    # "ungeklärt"). Answering it a second time here would be the same rule
    # enforced in two places, free to disagree.
    def billing_start_moment
      starts_on = @account.billing_starts_on
      return window_start if starts_on.blank? || starts_on <= @period_start

      @billing_start_moment ||= SeatSnapshot.boundary_moment(starts_on)
    end

    # A move writes moved_out in the old account and moved_in in the new, both
    # with ONE timestamp (Subscriptions::OrganisationMove). Distinct moments, so
    # a move of several pairs cuts the month once rather than once per person.
    def move_moments
      events_in_window.select { |event| Constants::SEAT_EVENT_MOVES.include?(event.event) }
                      .map(&:occurred_at).uniq
    end

    # A7: apply EVERY event carrying the same occurred_at, and only THEN measure.
    # Measuring after each single event would make the maximum depend on the
    # insertion order of simultaneous rows, with created_at as the tiebreaker --
    # and the move transitions from K5 deliberately share one timestamp, so this
    # is the normal case rather than a curiosity.
    def simultaneous_blocks
      events_in_window.slice_when { |a, b| a.occurred_at != b.occurred_at }.to_a
    end

    # Strictly greater, so the FIRST moment the peak was reached is the one
    # reported. "Since when was it this high" is the question a customer asks;
    # the last of several equal maxima would answer a different one.
    def measure(occupied)
      SeatSnapshot.distinct_user_count(occupied.values)
    end

    # `counted` is the single truth about whether a transition leaves the seat
    # occupied; the event TYPE is deliberately not consulted. SeatEvent validates
    # that the two agree (counted_matches_event), so re-deriving occupancy from
    # the type would be a second and weaker copy of that rule -- and `opening`
    # has no fixed expectation at all, it records whatever the state was.
    def apply(occupied, event)
      key = [event.organisation_id, event.user_id]
      return occupied.delete(key) unless event.counted

      occupied[key] = SeatSnapshot.pair_from(event)
    end

    # The snapshot's pairs, keyed for the replay. Read from the stored row rather
    # than reconstructed from the account's whole history -- being able to do
    # that is the entire purpose of the snapshot (§4 step 1).
    #
    # A STALE snapshot cannot be detected from here. After a backdated event
    # correction (§9) the row has to be recomputed with seat_snapshots:rebuild,
    # and until it is, this replay starts from the old opening. Named rather than
    # guarded: the only honest guard would be recomputing the row, and this
    # service deliberately does not write.
    def opening_state(snapshot)
      snapshot.pairs.each_with_object({}) do |pair, state|
        entry = pair.stringify_keys
        state[[entry['organisation_id'], entry['user_id']]] = entry
      end
    end

    # Loaded once, in one query. Hash#values hands back a fresh array each time,
    # and the pair hashes themselves are never mutated in place, so a captured
    # pairs_at_peak keeps the state of its own moment.
    def events_in_window
      @events_in_window ||= SeatEvent.for_account(@account)
                                     .strictly_between(window_start, window_end)
                                     .chronological.to_a
    end

    # Both ends through SeatSnapshot.boundary_moment, so both are Europe/Berlin
    # midnight (A6). Deriving only one of them there and the other with
    # beginning_of_month on a UTC Time is how a month ends up two hours long at
    # one end and not the other.
    def window_start
      @window_start ||= SeatSnapshot.boundary_moment(@period_start)
    end

    def window_end
      @window_end ||= SeatSnapshot.boundary_moment(@period_start.next_month)
    end

    def answer(status, reason: nil, sections: [], snapshot: nil)
      Result.new(account: @account, period_start: @period_start, status: status, reason: reason,
                 sections: sections, snapshot: snapshot,
                 window_start: window_start, window_end: window_end)
    end
  end
end
