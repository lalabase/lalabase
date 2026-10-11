# frozen_string_literal: true

require 'rails_helper'

# S3c T3: the ONE owner of "sum a time relation into the three billing buckets".
# It was extracted from the chat tool when the assistant's report panel became a
# second reader, so what is tested here is exactly what would drift apart if the
# extraction were undone: shape, precedence, and the single query.
RSpec.describe TimeSessions::BucketTotals do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(minutes:, billed: false, grouped: false, invoice: nil)
    group = grouped ? create(:time_session_group, organisation: organisation) : nil
    create(:time_session, project: project, organisation: organisation, creator: user,
                          duration: minutes, billed: billed, invoice_number: invoice,
                          time_session_group_id: group&.id, occurred_on: 2.days.ago)
  end

  def totals(scope = project.time_sessions)
    described_class.call(scope: scope)
  end

  # Kategorie 4: the shape is a contract, not a by-product of the query. A caller
  # reading totals['billed'] must never have to know whether that row came back.
  describe 'the shape' do
    it 'answers all three buckets zeroed for an empty relation' do
      expect(totals).to eq(
        'billed' => { minutes: 0, sessions: 0 },
        'in_billing' => { minutes: 0, sessions: 0 },
        'without_billing' => { minutes: 0, sessions: 0 }
      )
    end

    it 'still answers all three buckets when only one of them has rows' do
      book(minutes: 30)

      expect(totals.keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
      expect(totals['billed']).to eq(minutes: 0, sessions: 0)
    end

    it '.empty is that same shape, and a fresh object every call (no shared mutable state)' do
      first = described_class.empty
      first['billed'][:minutes] += 5

      expect(described_class.empty['billed'][:minutes]).to eq(0)
    end
  end

  # Kategorie 2: every bucket of the frozen whitelist gets its rows. Iterating the
  # CONSTANT means a bucket that is added or renamed shows up here, not in
  # production.
  describe 'every bucket of TimeSession::BILLING_STATUS_FILTERS' do
    let(:bookings) do
      {
        'billed' => -> { book(minutes: 60, billed: true, invoice: 'INV-1') },
        'in_billing' => -> { book(minutes: 30, grouped: true) },
        'without_billing' => -> { book(minutes: 15) }
      }
    end

    TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
      it "counts a #{bucket} session into #{bucket}" do
        bookings.fetch(bucket).call

        expect(totals[bucket][:sessions]).to eq(1)
        expect(totals.except(bucket).values.sum { |t| t[:sessions] }).to eq(0)
      end
    end

    it 'covers every bucket the constant knows (no bucket without a case above)' do
      expect(bookings.keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
    end
  end

  describe 'the precedence' do
    # "billed wins" lives in TimeSession.billing_bucket_for. This asserts that this
    # object asks it rather than re-deciding: a session that is billed AND in a
    # group counts once, as billed.
    it 'counts a session that is billed AND grouped as billed only' do
      book(minutes: 90, billed: true, grouped: true, invoice: 'INV-2')

      expect(totals['billed']).to eq(minutes: 90, sessions: 1)
      expect(totals['in_billing'][:sessions]).to eq(0)
    end
  end

  describe 'the sums' do
    it 'adds minutes and sessions per bucket' do
      book(minutes: 45)
      book(minutes: 15)

      expect(totals['without_billing']).to eq(minutes: 60, sessions: 2)
    end

    # The relation is the caller's business. This one proves the object counts what
    # it is GIVEN, which is what lets ViewingScope narrow before it.
    it 'counts only what the given relation contains' do
      book(minutes: 60)
      other = book(minutes: 999)

      expect(totals(project.time_sessions.where.not(id: other.id))['without_billing'])
        .to eq(minutes: 60, sessions: 1)
    end

    it 'ignores soft-deleted sessions, because the relation does' do
      book(minutes: 60)
      book(minutes: 120).update!(deleted_at: Time.current)

      expect(totals['without_billing']).to eq(minutes: 60, sessions: 1)
    end
  end

  describe 'the query' do
    # `unscope(:order)` is not cosmetic: an ORDER BY on a grouped query is a
    # Postgres error the moment the ordering column is not in the GROUP BY, and an
    # ordered relation is exactly what a list hands over.
    it 'survives an ordered relation' do
      book(minutes: 30)

      expect { totals(project.time_sessions.order(occurred_on: :desc)) }.not_to raise_error
    end

    it 'asks the database exactly once, however many buckets are filled' do
      book(minutes: 60, billed: true, invoice: 'INV-3')
      book(minutes: 30, grouped: true)
      book(minutes: 15)
      expect(count_queries { described_class.call(scope: project.time_sessions) }).to eq(1)
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
end
