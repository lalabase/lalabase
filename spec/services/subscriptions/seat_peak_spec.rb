# frozen_string_literal: true

require 'rails_helper'

# What: the monthly peak evaluation (M2, doc/abrechnungsmodell_plan.md A2/§4/§5).
# Type: service spec.
# Why:  this is the figure that becomes the invoice. The examples pin the
#       properties from §7 that fail SILENTLY when lost -- dedup across
#       organisations (a plus/minus counter answers plausibly and wrongly), the
#       Europe/Berlin month (a UTC month is off by two hours at each end),
#       immunity against the vacation and the cutoff trick (A2), order
#       independence of simultaneous events (A7), and NULL rather than zero for
#       a period nobody can reconstruct (§3).
#
# The boundary rows come from the REAL writer, not from hand-built snapshots: the
# seam between what M1 stores and what M2 reads is exactly where a silent
# mismatch would live, and a hand-built input would hide it.
#
# Events are written directly rather than through memberships -- the recorder has
# its own specs, here the input IS the stream, and synthetic rows keep every
# timestamp exact.
RSpec.describe Subscriptions::SeatPeak do
  include ActiveSupport::Testing::TimeHelpers

  let(:period) { Date.new(2026, 8, 1) }
  # HARDCODED UTC instants, never derived from SeatSnapshot.boundary_moment: an
  # expectation computed from the code under test stays green under any zone.
  # 2026-08-01 00:00 Europe/Berlin (CEST) and 2026-09-01 00:00 CEST.
  let(:boundary_utc) { Time.utc(2026, 7, 31, 22, 0, 0) }
  let(:next_boundary_utc) { Time.utc(2026, 8, 31, 22, 0, 0) }
  let(:mid_month) { Time.utc(2026, 8, 10, 12, 0, 0) }
  let(:account) { create(:account) }
  let(:org_one) { { id: SecureRandom.uuid, name: 'Org Eins' } }
  let(:org_two) { { id: SecureRandom.uuid, name: 'Org Zwei' } }
  let(:user_a) { SecureRandom.uuid }
  let(:user_b) { SecureRandom.uuid }
  let(:user_c) { SecureRandom.uuid }

  # September, so August is a CLOSED month in every example that does not say
  # otherwise. Without a fixed now, `provisional?` and the future-month branch
  # would answer differently depending on the day the suite runs.
  before { travel_to(Time.utc(2026, 9, 15, 9, 0, 0)) }

  # Only the stream marker. The accounts' own creation dates are deliberately NOT
  # backdated: reconstructible_from reads the marker alone, because before an
  # account existed it held zero seats and that is a measurement rather than an
  # unknown (see the signup-month example below). Setting created_at here would
  # be a dead line pretending to matter.
  def make_reconstructible(*_accounts, from: Time.utc(2026, 1, 1))
    SystemSetting.seat_stream_opened_at!(from)
  end

  # `counted` follows the event type rather than being passed alongside it:
  # SeatEvent validates that the two agree, and letting the caller set both would
  # invite an example that pins a row the writer could never produce.
  #
  # `opening` is the one type with no expectation -- it records whatever the
  # state WAS -- so there the caller's value stands, which is what the fallback
  # of fetch is for.
  def record(target, org:, user_id:, at:, counted: true, event: nil)
    event ||= counted ? Subscriptions::Constants::SEAT_EVENT_ACTIVATED : Subscriptions::Constants::SEAT_EVENT_DEACTIVATED
    SeatEvent.create!(account: target, organisation_id: org[:id],
                      organisation_name: org[:name], user_id: user_id, event: event,
                      occurred_at: at, billable: true,
                      counted: Subscriptions::Constants::SEAT_EVENT_COUNTED_EXPECTATION.fetch(event, counted))
  end

  # An organisation changing accounts (A3/K5): one moved_out in the old account
  # and one moved_in in the new, per pair, sharing ONE timestamp. That shared
  # timestamp is the reason A7 and the account filter exist.
  def move_organisation(org:, user_ids:, from:, to:, at:)
    user_ids.each do |user_id|
      record(from, org: org, user_id: user_id, at: at,
                   event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT)
      record(to, org: org, user_id: user_id, at: at,
                 event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN)
    end
  end

  # Lays the real boundary row for `target`, then asks for the peak.
  def evaluate(target = account, for_period: period)
    Subscriptions::SeatSnapshotWriter.call(period_start: for_period, account: target)
    described_class.call(account: target, period_start: for_period)
  end

  # The everyday month has exactly ONE section (M3/A3: only an org move or a
  # mid-month billing start splits it). `sole` rather than `first`, so an example
  # that unexpectedly produced two sections fails here instead of quietly
  # testing the first of them.
  def only_section(result)
    result.sections.sole
  end

  def named(section)
    section.organisations.map { |entry| entry['organisation_name'] }
  end

  describe 'dedup across organisations (D4.1, [CRITICAL] in §7)' do
    # THE case a plus/minus counter gets wrong: leaving organisation one frees no
    # seat while the same user still sits in organisation two of this account.
    it 'keeps the peak at one when the user leaves one of two organisations' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_a, at: mid_month, counted: false)

      result = evaluate

      expect(result).to be_ok
      expect(only_section(result).peak).to eq(1)
    end

    # §5 wants the organisations, and the per-organisation figures deliberately
    # sum to MORE than the peak. Both halves are asserted, because a breakdown
    # that quietly contradicts the headline number is worse than none.
    it 'names both organisations and the overlap between them' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: user_b, at: boundary_utc - 1.day)

      result = evaluate

      expect(only_section(result).peak).to eq(2)
      expect(only_section(result).organisations).to eq(
        [{ 'organisation_id' => org_two[:id], 'organisation_name' => 'Org Zwei', 'seats' => 2 },
         { 'organisation_id' => org_one[:id], 'organisation_name' => 'Org Eins', 'seats' => 1 }]
      )
      expect(only_section(result).shared_seats).to eq(1)
    end

    # [CRITICAL] A rename mid-month leaves the SAME organisation carrying two
    # frozen names: whoever joined afterwards has the new one, everyone else
    # still the old. Grouped by (id, name) that showed one organisation as two
    # rows with the same UUID, and shared_seats did not catch it because the sum
    # was right (review finding on #529, measured).
    #
    # The peak was never wrong. The BREAKDOWN ("Aufstellung") was, and §5 exists
    # precisely so the customer does not read a contradiction.
    it 'keeps a renamed organisation as one row and uses its newest name' do
      renamed = { id: org_one[:id], name: 'Neu GmbH' }
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      # Renamed on the 10th; only the newcomer's event carries the new name.
      record(account, org: renamed, user_id: user_c, at: mid_month + 2.days)

      result = evaluate

      expect(only_section(result).peak).to eq(3)
      expect(only_section(result).organisations).to eq(
        [{ 'organisation_id' => org_one[:id], 'organisation_name' => 'Neu GmbH', 'seats' => 3 }]
      )
      expect(only_section(result).shared_seats).to eq(0)
    end
  end

  describe 'the peak itself (A2)' do
    it 'reports the highest simultaneous state and when it was first reached' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_c, at: mid_month)
      record(account, org: org_one, user_id: user_c, at: mid_month + 2.days, counted: false)

      result = evaluate

      expect(only_section(result).peak).to eq(3)
      expect(only_section(result).peak_at).to eq(mid_month)
    end

    # Vacation (§7): deactivate and reactivate inside the month. The peak is
    # immune by construction -- an already reached maximum cannot fall.
    it 'is unchanged by a deactivation and reactivation within the month' do
      make_reconstructible(account)
      [user_a, user_b, user_c].each do |user_id|
        record(account, org: org_one, user_id: user_id, at: boundary_utc - 1.day)
      end
      record(account, org: org_one, user_id: user_c, at: mid_month, counted: false)
      record(account, org: org_one, user_id: user_c, at: mid_month + 10.days)

      result = evaluate

      expect(only_section(result).peak).to eq(3)
      expect(only_section(result).peak_at).to eq(boundary_utc)
    end

    # Cutoff (§7): the loophole every "state on the billing date" model has.
    it 'is unchanged when everyone is deactivated on the last day of the month' do
      make_reconstructible(account)
      [user_a, user_b, user_c].each do |user_id|
        record(account, org: org_one, user_id: user_id, at: boundary_utc - 1.day)
        record(account, org: org_one, user_id: user_id, at: next_boundary_utc - 1.hour, counted: false)
      end

      expect(only_section(evaluate).peak).to eq(3)
    end

    # Two equal maxima: the FIRST one is reported. "Since when was it this high"
    # is the question a customer asks about their invoice.
    it 'reports the first of several equal maxima' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: mid_month)
      record(account, org: org_one, user_id: user_b, at: mid_month + 1.day, counted: false)
      record(account, org: org_one, user_id: user_c, at: mid_month + 2.days)

      result = evaluate

      expect(only_section(result).peak).to eq(2)
      expect(only_section(result).peak_at).to eq(mid_month)
    end

    # [CRITICAL] The signup month of every new customer, and therefore the month
    # of their FIRST invoice. The account did not exist at the boundary, so its
    # state there is a known and trivial zero -- not an unknown. Answering
    # not_reconstructible here would leave the first billed month empty.
    #
    # Review finding on #529, measured before the fix: status was
    # not_reconstructible and peak nil, because reconstructible_from took the
    # LATER of marker and account creation.
    it 'answers the signup month of an account created mid-month' do
      SystemSetting.seat_stream_opened_at!(Time.utc(2026, 1, 1))
      # Sets the scene rather than driving the outcome: since the fix,
      # reconstructibility no longer depends on it, and that IS the point here.
      account.update_column(:created_at, Time.utc(2026, 8, 15, 9, 0, 0))
      record(account, org: org_one, user_id: user_a, at: Time.utc(2026, 8, 15, 9, 5, 0))

      result = evaluate

      expect(result).to be_ok
      expect(only_section(result).peak).to eq(1)
      expect(only_section(result).peak_at).to eq(Time.utc(2026, 8, 15, 9, 5, 0))
    end

    it 'answers zero for a reconstructible month in which nobody held a seat' do
      make_reconstructible(account)

      result = evaluate

      expect(result).to be_ok
      expect(only_section(result).peak).to eq(0)
      expect(only_section(result).organisations).to be_empty
    end

    # Money: another account's events in the same window must not leak in.
    # SeatEvent.for_account is the only thing keeping them apart.
    it 'ignores the events of a different account' do
      other = create(:account)
      make_reconstructible(account, other)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(other, org: org_two, user_id: user_b, at: mid_month)
      record(other, org: org_two, user_id: user_c, at: mid_month)

      expect(only_section(evaluate).peak).to eq(1)
    end
  end

  describe 'rotation (A2 together with A7)' do
    # No overlap: A leaves and C arrives at the SAME instant. Two seats before,
    # two after, never three.
    #
    # The ARRIVAL is written first on purpose. chronological breaks the tie on
    # created_at, so this is the order in which measuring after each single
    # event would count three, and the other order is the one where the bug
    # hides. Written the benign way round, this example passes with and without
    # A7 and proves nothing (measured: the mutation left it green).
    it 'stays at two when one seat is handed over at a single instant' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_c, at: mid_month)
      record(account, org: org_one, user_id: user_a, at: mid_month, counted: false)

      expect(only_section(evaluate).peak).to eq(2)
    end

    # WITH overlap, and this example only reads correctly next to the one above:
    # the seats really were occupied at the same time, so three is right. Without
    # both, the rule looks like "a handover never counts".
    it 'reports three when the arrival is hours before the departure' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_c, at: mid_month)
      record(account, org: org_one, user_id: user_a, at: mid_month + 8.hours, counted: false)

      result = evaluate

      expect(only_section(result).peak).to eq(3)
      expect(only_section(result).peak_at).to eq(mid_month)
    end

    # A7 as a property, not an anecdote: the same two simultaneous events in both
    # insertion orders. created_at is the only difference between the accounts,
    # and it must not reach the result.
    it 'gives the same peak in either insertion order of simultaneous events' do
      arrival_first = create(:account)
      departure_first = create(:account)
      make_reconstructible(arrival_first, departure_first)

      [arrival_first, departure_first].each do |target|
        record(target, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
        record(target, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      end
      record(arrival_first, org: org_one, user_id: user_c, at: mid_month)
      record(arrival_first, org: org_one, user_id: user_a, at: mid_month, counted: false)
      record(departure_first, org: org_one, user_id: user_a, at: mid_month, counted: false)
      record(departure_first, org: org_one, user_id: user_c, at: mid_month)
      # One sweep for both accounts: the writer reads the stream marker once per
      # call, and two calls in one example would trip the N+1 guard on it.
      Subscriptions::SeatSnapshotWriter.call(period_start: period)

      peaks = [arrival_first, departure_first].map do |target|
        only_section(described_class.call(account: target, period_start: period)).peak
      end

      expect(peaks.uniq).to eq([2])
    end
  end

  # §7 lists the move explicitly, and the code names it twice as the reason A7
  # and the account filter exist: the same pair carries a moved_out in the old
  # account and a moved_in in the new one, with the SAME timestamp. Until these
  # examples existed, no spec wrote a single moved_in or moved_out.
  describe 'an organisation moving to another account (A3/K5)' do
    let(:leaving) { create(:account, name: 'Abgebendes Konto') }
    let(:receiving) { create(:account, name: 'Aufnehmendes Konto') }
    let(:move_at) { Time.utc(2026, 8, 20, 10, 0, 0) }

    before do
      make_reconstructible(leaving, receiving)
      # Org Eins with two people sits in the leaving account from the boundary on.
      record(leaving, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(leaving, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      # The receiving account fills its OWN organisation mid-month. Deliberately
      # after the boundary: these rows are the ones a missing account filter
      # would pull into the leaving account's replay.
      record(receiving, org: org_two, user_id: user_c, at: mid_month)
      record(receiving, org: org_two, user_id: SecureRandom.uuid, at: mid_month)
      Subscriptions::SeatSnapshotWriter.call(period_start: period)
      move_organisation(org: org_one, user_ids: [user_a, user_b],
                        from: leaving, to: receiving, at: move_at)
    end

    # [CRITICAL] A3, and the reason M3 exists. Both accounts hold the same two
    # people in the same month, and without the cut both would be invoiced for
    # them. The peak is a maximum, so the DEPARTURE cannot lower the first
    # section -- what the split buys is that the second section no longer
    # carries them.
    #
    # Two, not four: four is what the leaving account answers once the account
    # filter is gone, because the receiving account's mid-month arrivals fall
    # inside the same window.
    it 'splits the old account at the move and drops the leavers from the later part' do
      sections = described_class.call(account: leaving, period_start: period).sections

      expect(sections.map(&:peak)).to eq([2, 0])
      expect(sections.first.peak_at).to eq(boundary_utc)
      expect(sections.map { |section| [section.first_day, section.last_day] })
        .to eq([[Date.new(2026, 8, 1), Date.new(2026, 8, 19)],
                [Date.new(2026, 8, 20), Date.new(2026, 8, 31)]])
    end

    it 'splits the new account at the move and picks the arrivals up there' do
      sections = described_class.call(account: receiving, period_start: period).sections

      expect(sections.map(&:peak)).to eq([2, 4])
      expect(sections.last.peak_at).to eq(move_at)
      expect(sections.last.organisations.map { |entry| entry['organisation_name'] })
        .to contain_exactly('Org Eins', 'Org Zwei')
    end

    # [CRITICAL] §7: "die Abschnitte summieren sich auf EINEN Monat". Asserted as
    # an exact Rational, which is why `share` is not a Float -- 19/31 + 12/31 has
    # to be 1 and not 0.9999999999999999.
    it 'gives each account exactly one month of days, not two' do
      [leaving, receiving].each do |target|
        sections = described_class.call(account: target, period_start: period).sections

        expect(sections.sum(&:share)).to eq(1)
        expect(sections.sum(&:days)).to eq(31)
      end
    end

    # The other half of "niemand zahlt doppelt": the moved pair appears in the
    # OLD account before the move and in the NEW one after it, and in neither of
    # the two opposite sections. The peaks alone cannot show this -- they are
    # counts -- so the organisations of each section are asserted by name.
    it 'never has the moved organisation in both accounts at the same time' do
      old_sections = described_class.call(account: leaving, period_start: period).sections
      new_sections = described_class.call(account: receiving, period_start: period).sections

      expect(named(old_sections.first)).to eq(['Org Eins'])
      expect(named(old_sections.last)).to be_empty
      expect(named(new_sections.first)).to eq(['Org Zwei'])
      expect(named(new_sections.last)).to contain_exactly('Org Eins', 'Org Zwei')
    end

    # That the seats really were RELEASED is invisible in August, where the
    # maximum hides it. September is where it shows, and it goes through the real
    # writer -- a moved_out that failed to release would carry the two people
    # into every following month of the old account, and every following invoice.
    it 'releases the seats from the old account for the following month' do
      Subscriptions::SeatSnapshotWriter.call(period_start: period.next_month)

      result = described_class.call(account: leaving, period_start: period.next_month)

      expect(result).to be_ok
      expect(only_section(result).peak).to eq(0)
      expect(only_section(described_class.call(account: receiving, period_start: period.next_month)).peak).to eq(4)
    end

    # The month AFTER the move has no cut left: the move events lie outside its
    # window. Pinned because a cut that leaked into every following month would
    # split every invoice from here on, and the peaks would still look right.
    it 'leaves the following month whole' do
      Subscriptions::SeatSnapshotWriter.call(period_start: period.next_month)

      result = described_class.call(account: receiving, period_start: period.next_month)

      expect(result.sections.size).to eq(1)
      expect(result).not_to be_split
    end
  end

  # A3's second cut, and the one that hits EVERY customer: the first month of the
  # business relationship. Without it the first invoice is either a full month
  # for three days or a matter of opinion.
  describe 'a billing start inside the month (A3)' do
    let(:user_d) { SecureRandom.uuid }
    let(:user_e) { SecureRandom.uuid }

    before { make_reconstructible(account) }

    # [CRITICAL] The days BEFORE the start are not invoiced, so their peak must
    # not reach the section that is. Four people sat there in the first half of
    # August and the answer is still three -- without the fast-forward this
    # example reads 4 and the customer pays for a week they were not a customer.
    it 'measures only from the start date and ignores the higher peak before it' do
      account.update!(billing_starts_on: Date.new(2026, 8, 28))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: Time.utc(2026, 8, 5, 9, 0, 0))
      record(account, org: org_one, user_id: user_d, at: Time.utc(2026, 8, 5, 9, 0, 0))
      record(account, org: org_one, user_id: user_e, at: Time.utc(2026, 8, 5, 9, 0, 0))
      record(account, org: org_one, user_id: user_d, at: Time.utc(2026, 8, 20, 9, 0, 0), counted: false)
      record(account, org: org_one, user_id: user_e, at: Time.utc(2026, 8, 20, 9, 0, 0), counted: false)
      record(account, org: org_one, user_id: user_c, at: Time.utc(2026, 8, 29, 9, 0, 0))

      section = only_section(evaluate)

      expect(section.peak).to eq(3)
      expect(section.peak_at).to eq(Time.utc(2026, 8, 29, 9, 0, 0))
    end

    # §7: "Start am 28. ergibt drei Tage anteilig, keinen vollen Monat." August
    # has 31 days, so the 28th leaves four of them; the property is that it is a
    # PART of the month and that the denominator is the calendar month.
    it 'bills only the days from the start date on' do
      account.update!(billing_starts_on: Date.new(2026, 8, 28))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      section = only_section(evaluate)

      expect(section.first_day).to eq(Date.new(2026, 8, 28))
      expect(section.last_day).to eq(Date.new(2026, 8, 31))
      expect(section.days).to eq(4)
      expect(section.share).to eq(Rational(4, 31))
    end

    # [CRITICAL] The display hangs on this, and hanging it on the section COUNT
    # instead showed the first month of every customer as a full one (review
    # finding on #533). One section is NOT the same as a whole month.
    it 'marks a lone partial section as not the whole month' do
      account.update!(billing_starts_on: Date.new(2026, 8, 28))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      result = evaluate

      expect(result).not_to be_split
      expect(only_section(result)).not_to be_whole_month
      expect(result).to be_detailed(only_section(result))
    end

    it 'marks a lone full section as the whole month' do
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      result = evaluate

      expect(only_section(result)).to be_whole_month
      expect(result).not_to be_detailed(only_section(result))
    end

    # A month before the start is answered WITHOUT looking at the snapshot, and
    # this example is built so that the snapshot cannot answer either: no
    # boundary was ever written. Asked the other way round the operator is told
    # to run a backfill for a month that will never be invoiced.
    it 'answers not_billable even when no boundary was ever written' do
      account.update!(billing_starts_on: Date.new(2026, 9, 15))

      result = described_class.call(account: account, period_start: period)

      expect(result).to be_not_billable
      expect(result.snapshot).to be_nil
    end

    it 'leaves a month whole when billing began before it' do
      account.update!(billing_starts_on: Date.new(2026, 5, 17))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      section = only_section(evaluate)

      expect(section.first_day).to eq(Date.new(2026, 8, 1))
      expect(section.share).to eq(1)
    end

    # A start on the first is not a cut: one full section, not a zero-day one
    # followed by the rest.
    it 'leaves a month whole when billing begins on its first day' do
      account.update!(billing_starts_on: Date.new(2026, 8, 1))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      expect(only_section(evaluate).days).to eq(31)
    end

    # A month before the relationship began is measurable and deliberately
    # outside it. Its own status, because "nobody could look" and "nothing to
    # charge for" ask a human for different things -- and a full-month section
    # here would be an invoice line for a month the customer was not a customer.
    it 'answers not_billable for a month before the start date' do
      account.update!(billing_starts_on: Date.new(2026, 9, 15))
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      result = evaluate

      expect(result).to be_not_billable
      expect(result.sections).to be_empty
      expect(result.reason_key).to eq(described_class::STATUS_NOT_BILLABLE)
    end

    # A nil start means "undecided" under R1, not "never pays". Whether such an
    # account may be invoiced is Subscriptions::BillingList's question, and
    # answering it a second time here would be the same rule in two places.
    it 'treats an undecided start as no cut at all' do
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      expect(account.billing_starts_on).to be_nil
      expect(only_section(evaluate).days).to eq(31)
    end
  end

  # An `opening` is not a move. It records a starting state, it moves nobody
  # between accounts, and cutting a month at the backfill moment would invent a
  # boundary nobody agreed to -- half a month billed at one rate and half at
  # another, because an operator ran a task.
  #
  # Reachable, if narrowly: a re-run of the opening backfill writes an opening
  # for a pair it could not see the first time (an organisation that had no
  # account back then), and that lands inside a month the marker already makes
  # reconstructible. Built by hand here, because producing it through the
  # backfill would take the whole "organisation without account" hole with it.
  it 'is not cut by an opening event inside the month' do
    make_reconstructible(account)
    record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
    Subscriptions::SeatSnapshotWriter.call(period_start: period, account: account)
    record(account, org: org_two, user_id: user_b, at: mid_month,
                    event: Subscriptions::Constants::SEAT_EVENT_OPENING)

    result = described_class.call(account: account, period_start: period)

    expect(result).not_to be_split
    expect(only_section(result).days).to eq(31)
    expect(only_section(result).peak).to eq(2)
  end

  # Two moves in one month. Covers what no other example does: MORE than one cut,
  # so the sections have to CHAIN -- each opening on the state its predecessor
  # ended in -- rather than the second cut replacing the first.
  #
  # The day split 2 + 17 + 12 was picked because plain Float addition of those
  # three shares gives 0.9999999999999999. It does NOT prove that `share` must
  # be a Rational: Array#sum compensates float error (Kahan), so the sum below
  # is exactly 1.0 either way. Measured, not assumed. What pins the Rational is
  # the rake breakdown, which prints numerator and denominator.
  describe 'several cuts in one month' do
    it 'chains the sections and still adds up to exactly one month' do
      first_host = create(:account)
      second_host = create(:account)
      make_reconstructible(account, first_host, second_host)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: user_c, at: boundary_utc - 1.day)
      Subscriptions::SeatSnapshotWriter.call(period_start: period)
      move_organisation(org: org_one, user_ids: [user_a, user_b],
                        from: account, to: first_host, at: Time.utc(2026, 8, 3, 9, 0, 0))
      move_organisation(org: org_two, user_ids: [user_c],
                        from: account, to: second_host, at: Time.utc(2026, 8, 20, 9, 0, 0))

      sections = described_class.call(account: account, period_start: period).sections

      expect(sections.map(&:peak)).to eq([3, 1, 0])
      expect(sections.map(&:days)).to eq([2, 17, 12])
      expect(sections.sum(&:share)).to eq(1)
    end
  end

  # A6 hands the whole cut day to the new section. A move early on the FIRST of
  # the month therefore leaves the outgoing arrangement with real measured hours
  # and zero billed days. The section is still reported: its peak happened, and
  # dropping it would make a measured stretch of the month vanish silently.
  describe 'a cut on the first day of the month' do
    it 'gives the outgoing section zero days and still reports it' do
      other = create(:account)
      make_reconstructible(account, other)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: boundary_utc - 1.day)
      Subscriptions::SeatSnapshotWriter.call(period_start: period)
      move_organisation(org: org_one, user_ids: [user_a, user_b],
                        from: account, to: other, at: Time.utc(2026, 8, 1, 8, 0, 0))

      sections = described_class.call(account: account, period_start: period).sections

      expect(sections.map(&:peak)).to eq([2, 0])
      expect(sections.map(&:days)).to eq([0, 31])
      expect(sections.first).not_to be_billed
      expect(sections.sum(&:share)).to eq(1)
      # The SECOND section really does cover every day of the month, and it
      # still has to be labelled: an unlabelled full month next to a labelled
      # zero-day one reads as a rendering error rather than as the truth.
      result = described_class.call(account: account, period_start: period)
      expect(sections.last).to be_whole_month
      expect(result).to be_detailed(sections.last)
    end
  end

  describe 'the month is a German calendar month (A6)' do
    # 2026-08-01 00:30 Europe/Berlin. Both halves are asserted, and the July half
    # is the one that discriminates: under UTC boundaries this instant would fall
    # into July's window, so a July peak of 1 is exactly the failure. Asserting
    # only the August half would pass either way, because a UTC July snapshot
    # would carry the seat into August's opening state.
    let(:just_after_midnight_local) { Time.utc(2026, 7, 31, 22, 30, 0) }

    before do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: just_after_midnight_local)
    end

    it 'counts an activation just after local midnight into the new month' do
      result = evaluate

      expect(only_section(result).peak).to eq(1)
      expect(only_section(result).peak_at).to eq(just_after_midnight_local)
    end

    it 'does not count it into the previous month' do
      result = evaluate(for_period: Date.new(2026, 7, 1))

      expect(result).to be_ok
      expect(only_section(result).peak).to eq(0)
    end
  end

  # The END of the window is exclusive, and unlike the start that is
  # load-bearing: the next boundary belongs to the next month's snapshot, so
  # counting an event sitting exactly on it would let a September activation
  # raise an August invoice.
  it 'excludes an event sitting exactly on the next month boundary' do
    make_reconstructible(account)
    record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
    record(account, org: org_one, user_id: user_b, at: next_boundary_utc)

    expect(only_section(evaluate).peak).to eq(1)
  end

  describe 'references that outlive their records' do
    # The normal end state of these rows. The frozen organisation_name is the
    # only thing that can still answer "which organisations" (§5) afterwards.
    it 'keeps naming an organisation that no longer exists' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: user_b, at: mid_month)
      # Organisation deleted: the recorder writes `removed` for every seat.
      [user_a, user_b].each do |user_id|
        record(account, org: org_one, user_id: user_id, at: mid_month + 5.days,
                        counted: false, event: Subscriptions::Constants::SEAT_EVENT_REMOVED)
      end

      result = evaluate

      expect(only_section(result).peak).to eq(2)
      expect(only_section(result).organisations.map { |entry| entry['organisation_name'] }).to eq(['Org Eins'])
    end

    # Dedup runs on user_id and must not depend on the User row still being
    # there -- otherwise an anonymisation would quietly change a past invoice.
    it 'still counts a user whose record has been deleted' do
      user = create(:user)
      make_reconstructible(account)
      record(account, org: org_one, user_id: user.id, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: user.id, at: boundary_utc - 1.day)
      Subscriptions::SeatSnapshotWriter.call(period_start: period, account: account)
      # delete_all, not destroy!: the row has to be REALLY gone, otherwise this
      # example would pass with a soft-deleted user and prove nothing. The
      # absence is asserted rather than assumed for the same reason.
      ::User.where(id: user.id).delete_all
      expect(::User.unscoped.exists?(user.id)).to be(false)

      result = described_class.call(account: account, period_start: period)

      expect(only_section(result).peak).to eq(1)
      expect(only_section(result).organisations.size).to eq(2)
    end
  end

  describe 'when there is no answer' do
    # §3: a period before the stream opened yields NO result, never a zero. A
    # zero would travel onto an invoice as "no seats" instead of "nobody looked".
    it 'reports not_reconstructible for a period before the stream opened' do
      SystemSetting.seat_stream_opened_at!(Time.utc(2026, 8, 20))

      result = evaluate

      expect(result).to be_not_reconstructible
      expect(result.sections).to be_empty
    end

    # Missing and failed are kept apart from not_reconstructible on purpose: the
    # first two are repairable by running the job, the third never is.
    it 'reports unavailable when the boundary was never written' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      result = described_class.call(account: account, period_start: period)

      expect(result).to be_unavailable
      expect(result.reason).to eq(described_class::REASON_SNAPSHOT_MISSING)
      expect(result.sections).to be_empty
    end

    it 'reports unavailable when the boundary write failed' do
      make_reconstructible(account)
      create(:seat_snapshot, account: account, period_start: period,
                             status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                             seat_count: nil, pairs: [], error: 'PG::Error: boom')

      result = described_class.call(account: account, period_start: period)

      expect(result).to be_unavailable
      expect(result.reason).to eq(described_class::REASON_SNAPSHOT_FAILED)
      expect(result.snapshot.error).to eq('PG::Error: boom')
    end

    # An answer rather than an exception, deliberately: a click on the wrong
    # month in the admin backend must not be a 500.
    it 'reports unavailable for a month that has not begun' do
      result = described_class.call(account: account, period_start: Date.new(2026, 10, 1))

      expect(result).to be_unavailable
      expect(result.reason).to eq(described_class::REASON_MONTH_NOT_STARTED)
    end
  end

  describe 'the running month' do
    # The figure of a month still in progress can still grow. It is a reading,
    # not a result, and nothing may put it on an invoice.
    it 'is marked provisional' do
      travel_to(Time.utc(2026, 8, 20, 9, 0, 0))
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      result = evaluate

      expect(result).to be_ok
      expect(result).to be_provisional
    end

    it 'is not marked provisional once the month is over' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.day)

      expect(evaluate).not_to be_provisional
    end
  end
end
