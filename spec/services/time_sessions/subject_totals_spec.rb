# frozen_string_literal: true

require 'rails_helper'

# The batch twin of SubjectTimeSummaryService: the same question ("what is booked
# on this ticket, and where does it stand?") for a whole page in one query. What
# is pinned here is what would rot if a later change made it per-row again: the
# single query, the entry for a ticket with nothing booked, and that it counts
# only the relation it is handed (which is how ViewingScope narrows it).
RSpec.describe TimeSessions::SubjectTotals do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:second_ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(on:, minutes: 60, billed: false, grouped: false, invoice: nil, creator: user)
    group = grouped ? create(:time_session_group, organisation: organisation) : nil
    create(:time_session, project: project, organisation: organisation, creator: creator,
                          ticket: on, duration: minutes, billed: billed, invoice_number: invoice,
                          time_session_group_id: group&.id, occurred_on: 2.days.ago)
  end

  def totals(ids, scope = project.time_sessions)
    described_class.call(scope: scope, ticket_ids: ids)
  end

  describe 'the shape' do
    # A view reads totals[ticket.id] for every row it renders. If a ticket without
    # bookings were missing from the hash, the cell would have to nil-check, and the
    # first caller that forgets is a 500 in a list.
    it 'answers a zeroed entry for a ticket that has nothing booked' do
      expect(totals([ticket.id])[ticket.id]).to eq(described_class.empty_entry)
    end

    it 'answers an entry for every requested id, booked or not' do
      book(on: ticket)

      expect(totals([ticket.id, second_ticket.id]).keys).to match_array([ticket.id, second_ticket.id])
    end

    it 'is empty for no ids at all, without touching the database' do
      scope = project.time_sessions # built outside the counter: a lazy let would be counted

      expect(count_queries { described_class.call(scope: scope, ticket_ids: []) }).to eq(0)
    end

    it '.empty_entry is a fresh hash every call (no shared mutable state)' do
      described_class.empty_entry[:minutes] += 5

      expect(described_class.empty_entry[:minutes]).to eq(0)
    end
  end

  describe 'the sums' do
    it 'adds the minutes booked on one ticket' do
      book(on: ticket, minutes: 45)
      book(on: ticket, minutes: 15)

      expect(totals([ticket.id])[ticket.id]).to include(minutes: 60, sessions: 2)
    end

    it 'keeps two tickets apart' do
      book(on: ticket, minutes: 30)
      book(on: second_ticket, minutes: 90)

      result = totals([ticket.id, second_ticket.id])
      expect(result[ticket.id][:minutes]).to eq(30)
      expect(result[second_ticket.id][:minutes]).to eq(90)
    end

    it 'ignores time booked on no ticket at all' do
      book(on: nil, minutes: 500)
      book(on: ticket, minutes: 30)

      expect(totals([ticket.id])[ticket.id][:minutes]).to eq(30)
    end

    it 'ignores soft-deleted sessions, because the relation does' do
      book(on: ticket, minutes: 60)
      book(on: ticket, minutes: 120).update!(deleted_at: Time.current)

      expect(totals([ticket.id])[ticket.id]).to include(minutes: 60, sessions: 1)
    end
  end

  describe 'the billing status' do
    it 'reports :without_billing for unassigned time' do
      book(on: ticket)

      expect(totals([ticket.id])[ticket.id][:billing_status]).to eq(:without_billing)
    end

    it 'reports :in_billing for time in an open billing' do
      book(on: ticket, grouped: true)

      expect(totals([ticket.id])[ticket.id][:billing_status]).to eq(:in_billing)
    end

    it 'reports :billed for invoiced time' do
      book(on: ticket, billed: true, invoice: 'INV-1')

      expect(totals([ticket.id])[ticket.id][:billing_status]).to eq(:billed)
    end

    it 'reports :mixed when the ticket holds two states at once' do
      book(on: ticket, billed: true, invoice: 'INV-2')
      book(on: ticket)

      expect(totals([ticket.id])[ticket.id][:billing_status]).to eq(:mixed)
    end

    # "billed wins" belongs to TimeSession.billing_bucket_for. This proves the
    # object asks it rather than deciding again: billed AND grouped is one bucket,
    # so the ticket is :billed, not :mixed.
    it 'does not turn a billed, grouped session into two states' do
      book(on: ticket, billed: true, grouped: true, invoice: 'INV-3')

      expect(totals([ticket.id])[ticket.id][:billing_status]).to eq(:billed)
    end

    it 'reports :no_sessions for a ticket with nothing booked' do
      book(on: second_ticket)

      expect(totals([ticket.id, second_ticket.id])[ticket.id][:billing_status]).to eq(:no_sessions)
    end
  end

  # This is the rights property, seen from here: the object counts what it is
  # given. TimeSessions::ViewingScope narrows before it, and a narrowed relation
  # must produce a smaller number, not the full one.
  describe 'the given relation' do
    it 'counts only what the relation contains' do
      book(on: ticket, minutes: 60, creator: user)
      book(on: ticket, minutes: 900, creator: other_user)

      scope = TimeSessions::ViewingScope.new(user: user, project: project).call
                                        .tap { |s| allow(s).to receive(:tier).and_return(:own) }

      expect(totals([ticket.id], scope.apply(project.time_sessions))[ticket.id])
        .to include(minutes: 60, sessions: 1)
    end

    it 'answers zeroed entries for a relation that may show nothing' do
      book(on: ticket, minutes: 60)

      expect(totals([ticket.id], project.time_sessions.none)[ticket.id])
        .to eq(described_class.empty_entry)
    end

    it 'does not report a ticket whose time lives outside the relation' do
      book(on: ticket, minutes: 60)
      other_project_ticket = create(:ticket, project: create(:project, organisation: organisation),
                                             organisation: organisation)

      expect(totals([ticket.id, other_project_ticket.id])[other_project_ticket.id])
        .to eq(described_class.empty_entry)
    end
  end

  describe 'the query' do
    # An ordered relation is exactly what a list hands over, and an ORDER BY on a
    # grouped query is a Postgres error the moment the column is not grouped.
    it 'survives an ordered relation' do
      book(on: ticket)

      expect { totals([ticket.id], project.time_sessions.order(occurred_on: :desc)) }.not_to raise_error
    end

    # The whole reason this object exists. Noise rows FIRST, so a short circuit
    # cannot make the guard pass by finding nothing to do.
    it 'asks the database exactly once for a page of many tickets in many states' do
      # Prosopite.pause: the repeated organisation read is factory setup, not the
      # object under test. It stays outside the counter for the same reason.
      tickets = Prosopite.pause do
        Array.new(5) { create(:ticket, project: project, organisation: organisation) }.each_with_index do |t, i|
          book(on: t, minutes: 30, billed: i.even?, invoice: i.even? ? "INV-#{i}" : nil)
          book(on: t, minutes: 15, grouped: true)
        end
      end

      expect(count_queries { described_class.call(scope: project.time_sessions, ticket_ids: tickets.map(&:id)) })
        .to eq(1)
    end
  end

  def count_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])
      next if payload[:sql] =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

      count += 1
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # The billing column draws the same share bar as the time list (plan §4), and
  # the minutes it needs were being SELECTED and then dropped: the query already
  # groups by billed and grouped and sums the durations.
  describe 'the minutes per bucket' do
    it 'keeps them, so a caller can draw a bar without a second query' do
      book(on: ticket, minutes: 60, billed: true, invoice: 'INV-9')
      book(on: ticket, minutes: 30, grouped: true)
      book(on: ticket, minutes: 90)

      entry = totals([ticket.id]).fetch(ticket.id)

      expect(entry[:shares]).to eq('billed' => 60, 'in_billing' => 30, 'without_billing' => 90)
      expect(entry[:percent]).to eq(33)
    end

    it 'always carries all three keys, so a view never has to nil-check a bucket' do
      book(on: ticket, minutes: 60)

      expect(totals([ticket.id]).fetch(ticket.id)[:shares].keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
      expect(described_class.empty_entry[:shares].keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
    end

    it 'has nothing to draw and no share to name for a ticket with nothing booked' do
      entry = described_class.empty_entry

      expect(entry[:shares].values).to all(be_zero)
      expect(entry[:percent]).to be_nil
    end
  end
end
