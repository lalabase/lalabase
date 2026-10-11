# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the seat_peaks:* operator tasks (M2, doc/abrechnungsmodell_plan.md §5).
# Type: Rake task spec.
# Why:  under R1 a human answers "why does it say five" from this output, so the
#       output IS the feature, not a debug aid. Three properties would be wrong
#       in a way nobody notices: the timestamp printed in UTC next to a German
#       calendar month (two hours off, and it LOOKS right), a missing answer
#       shown as a bare peak of nothing, and the per-organisation figures adding
#       up to more than the peak without saying why.
RSpec.describe 'seat_peaks' do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('seat_peaks:show')
  end

  before do
    %w[seat_peaks:month seat_peaks:show].each { |name| Rake::Task[name].reenable }
    travel_to(Time.utc(2026, 9, 15, 9, 0, 0))
  end

  let(:period) { Date.new(2026, 8, 1) }
  # 2026-08-01 00:00 Europe/Berlin, hardcoded rather than derived from the code
  # under test.
  let(:boundary_utc) { Time.utc(2026, 7, 31, 22, 0, 0) }
  let(:account) { create(:account, name: 'Beispiel GmbH') }
  let(:org_one) { { id: SecureRandom.uuid, name: 'Org Eins' } }
  let(:org_two) { { id: SecureRandom.uuid, name: 'Org Zwei' } }

  # Only the stream marker: reconstructible_from reads it alone, so backdating
  # the accounts would be a dead line pretending to matter.
  def make_reconstructible(*_accounts, from: Time.utc(2026, 1, 1))
    SystemSetting.seat_stream_opened_at!(from)
  end

  def record(target, org:, user_id:, at:, counted: true)
    event = counted ? Subscriptions::Constants::SEAT_EVENT_ACTIVATED : Subscriptions::Constants::SEAT_EVENT_DEACTIVATED
    SeatEvent.create!(account: target, organisation_id: org[:id],
                      organisation_name: org[:name], user_id: user_id,
                      event: event, occurred_at: at, billable: true, counted: counted)
  end

  def lay_boundary(target)
    Subscriptions::SeatSnapshotWriter.call(period_start: period, account: target)
  end

  # An organisation changing accounts: moved_out in the old and moved_in in the
  # new, one shared timestamp. This is the only thing besides a mid-month
  # billing start that splits a month (A3).
  def move_organisation(org:, user_ids:, from:, to:, at:)
    user_ids.each do |user_id|
      [[from, Subscriptions::Constants::SEAT_EVENT_MOVED_OUT, false],
       [to, Subscriptions::Constants::SEAT_EVENT_MOVED_IN, true]].each do |target, event, counted|
        SeatEvent.create!(account: target, organisation_id: org[:id],
                          organisation_name: org[:name], user_id: user_id,
                          event: event, occurred_at: at, billable: true, counted: counted)
      end
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe 'seat_peaks:show' do
    def run_show(account_id: account.id, period_start: period.to_s)
      Rake::Task['seat_peaks:show'].invoke(account_id, period_start)
    end

    # 12:00 UTC is 14:00 in Europe/Berlin. The month boundaries are formed in
    # that zone (A6), so printing the moment in UTC would put the peak two hours
    # earlier than it was -- and the line would look perfectly plausible.
    it 'prints the peak and its moment in Europe/Berlin' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      record(account, org: org_one, user_id: SecureRandom.uuid, at: Time.utc(2026, 8, 10, 12, 0, 0))
      lay_boundary(account)

      expect { run_show }.to output(/Hoechststand\s+2 Plätze.*erreicht am\s+10\.08\.2026 14:00/m).to_stdout
    end

    # §5: the organisations, and the sentence that keeps their sum from reading
    # as a contradiction.
    it 'names the organisations and explains the overlap between them' do
      shared_user = SecureRandom.uuid
      make_reconstructible(account)
      record(account, org: org_one, user_id: shared_user, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: shared_user, at: boundary_utc - 1.day)
      record(account, org: org_two, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(account)

      expect { run_show }.to output(/Org Zwei\s+2.*Org Eins\s+1.*Hinweis.*nur einmal gezählt/m).to_stdout
    end

    # A split month has no single peak (A9), so the breakdown lists the sections
    # with their days. Without the day figures the two blocks read like two full
    # months, which is the misunderstanding the split exists to prevent.
    it 'lists both sections with their days when the month is split' do
      other = create(:account, name: 'Aufnehmendes Konto')
      make_reconstructible(account, other)
      record(account, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(account)
      lay_boundary(other)
      move_organisation(org: org_one, user_ids: [SeatEvent.last.user_id],
                        from: account, to: other, at: Time.utc(2026, 8, 20, 10, 0, 0))

      lines = capture_stdout { run_show }.lines.map(&:strip)

      expect(lines).to include(a_string_matching(/\AAbschnitt 1 von 2\s+01\.08\. bis 19\.08\., 19 T\./))
      expect(lines).to include(a_string_matching(/\AAbschnitt 2 von 2\s+20\.08\. bis 31\.08\., 12 T\./))
      expect(lines).to include(a_string_matching(%r{Anteil\s+19/31 des Monats}))
    end

    # [CRITICAL] A lone four-day section used to print "Ein Abschnitt, ganzer
    # Monat" and, four rows below it, "Anteil 4/31 des Monats" -- two sentences
    # on one screen contradicting each other (review finding on #533).
    it 'does not claim a whole month for a lone partial section' do
      make_reconstructible(account)
      account.update!(billing_starts_on: Date.new(2026, 8, 28))
      record(account, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(account)

      lines = capture_stdout { run_show }.lines.map(&:strip)

      expect(lines).to include(a_string_matching(/\AEin Abschnitt\s+28\.08\. bis 31\.08\., 4 T\./))
      expect(lines).to include(a_string_matching(%r{Anteil\s+4/31 des Monats}))
      expect(lines).not_to include(a_string_matching(/ganzer Monat/))
    end

    # A month before the billing start is measurable and deliberately outside
    # the relationship. It gets the same treatment as the other no-answer cases:
    # a sentence, and exit 0.
    it 'names the reason for a month before the billing start' do
      make_reconstructible(account)
      account.update!(billing_starts_on: Date.new(2026, 9, 15))
      lay_boundary(account)

      expect { run_show }.to output(/vor dem Abrechnungsbeginn/).to_stdout
    end

    # A month without an answer is a normal question, not an operator error: it
    # prints the reason and ends with exit 0. Contrast seat_events:verify, which
    # aborts, because a drift finding means nothing may be invoiced at all.
    it 'prints the reason and does not abort when the boundary is missing' do
      make_reconstructible(account)

      expect { run_show }.to output(/noch kein Schnappschuss geschrieben/).to_stdout
    end

    # "Augustsonstwas" is not a typo in the example, it is the point: Date.parse
    # reads it as 2026-08-01 and answers confidently about a month nobody asked
    # for. The task uses Date.iso8601 because of this example.
    it 'aborts on an unparseable date instead of guessing a month' do
      expect { run_show(period_start: 'Augustsonstwas') }.to raise_error(SystemExit)
                                                         .and output(/kein Datum/).to_stderr
    end

    # Gets past Date.iso8601 as a valid Date (year 10000 BC) and would otherwise
    # reach the database, where it raises PG::DatetimeFieldOverflow instead of
    # the friendly abort. Review finding on #529.
    it 'aborts on a year the database cannot store' do
      account # the abort must come BEFORE any query, so give it a row to trip on
      expect { run_show(period_start: '-9999-01-01') }.to raise_error(SystemExit)
                                                      .and output(/kein Datum/).to_stderr
    end

    it 'aborts on an unknown account' do
      expect { run_show(account_id: SecureRandom.uuid) }.to raise_error(SystemExit)
                                                        .and output(/kein Konto/).to_stderr
    end
  end

  describe 'seat_peaks:month' do
    def run_month(period_start: period.to_s)
      Rake::Task['seat_peaks:month'].invoke(period_start)
    end

    # One line per account, with the two states that can differ BETWEEN accounts
    # in the same month: a measured peak and a boundary that was never written.
    # Telling those apart before an invoicing round is what the overview is for.
    it 'lists every account with its peak or the reason there is none' do
      measured = account
      unwritten = create(:account, name: 'Ohne Grenze')
      make_reconstructible(measured, unwritten)
      record(measured, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(measured)

      # Line by line rather than one long regex across newlines: a single
      # ordered pattern fails as a wall of text and hides WHICH state came out
      # wrong.
      lines = capture_stdout { run_month }.lines.map(&:strip)

      expect(lines).to include(a_string_matching(/\ABeispiel GmbH\s+1, seit 01\.08\.2026 00:00/))
      expect(lines).to include(a_string_matching(/\AOhne Grenze\s+.*noch kein Schnappschuss/))
    end

    # "Not reconstructible" is a property of the MONTH, not of a single account:
    # it hangs on the one global marker, so within a period it is all or nothing.
    # That became true with the #529 review fix, where an account younger than
    # the marker stopped being a special case, and it is pinned here so nobody
    # goes looking for a per-account variant of this line again.
    it 'reports a period before the stream opened for every account at once' do
      other = create(:account, name: 'Zweites Konto')
      SystemSetting.seat_stream_opened_at!(Time.utc(2026, 8, 20))
      lay_boundary(account)
      lay_boundary(other)

      lines = capture_stdout { run_month }.lines.map(&:strip)

      expect(lines).to include(a_string_matching(/\ABeispiel GmbH\s+.*nicht rekonstruieren/))
      expect(lines).to include(a_string_matching(/\AZweites Konto\s+.*nicht rekonstruieren/))
    end

    # One line has to carry a split month too, and the overview is read at a
    # glance -- so the peaks come with their stretches rather than as two bare
    # numbers.
    it 'puts both sections of a split month on one line' do
      other = create(:account, name: 'Aufnehmendes Konto')
      make_reconstructible(account, other)
      record(account, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(account)
      lay_boundary(other)
      move_organisation(org: org_one, user_ids: [SeatEvent.last.user_id],
                        from: account, to: other, at: Time.utc(2026, 8, 20, 10, 0, 0))

      lines = capture_stdout { run_month }.lines.map(&:strip)

      expect(lines).to include(
        a_string_matching(/\ABeispiel GmbH\s+1 \(01\.08\. bis 19\.08\., 19 T\.\), 0 \(20\.08\. bis 31\.08\., 12 T\.\)/)
      )
    end

    # The running month can still grow. Marked, because an operator copying the
    # figure onto an invoice is exactly what this line prevents.
    it 'marks the running month as provisional' do
      travel_to(Time.utc(2026, 8, 20, 9, 0, 0))
      make_reconstructible(account)
      record(account, org: org_one, user_id: SecureRandom.uuid, at: boundary_utc - 1.day)
      lay_boundary(account)

      expect { run_month }.to output(/Beispiel GmbH\s+1, seit .* \(laufender Monat\)/).to_stdout
    end

    it 'aborts on an unparseable date instead of guessing a month' do
      expect { run_month(period_start: 'letzter Monat') }.to raise_error(SystemExit)
                                                         .and output(/kein Datum/).to_stderr
    end
  end
end
