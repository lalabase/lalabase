# frozen_string_literal: true

require 'rails_helper'

# Folding one more event into a notification row that already exists: what a
# fold writes, what a refusal leaves alone, and that the decision is taken on
# the row as the database holds it under the lock. The lock itself, against a
# second connection: row_events_concurrency_spec.rb. And the rule both writers
# of last_event_at ask, a fold and a new row: the arrival of an event, with its
# one exception for a row read the moment it is written.
RSpec.describe Notifications::RowEvents, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:actor) { create(:user) }
  let(:other_actor) { create(:user) }
  let(:recipient) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # The moment an event reaches a row that is written now. The clock stands
  # still, and the event lies before it, on it or after it.
  describe '.arrival' do
    include ActiveSupport::Testing::TimeHelpers

    let(:now) { Time.zone.local(2026, 11, 24, 14, 10, 0) }

    before { travel_to(now) }
    after { travel_back }

    it 'answers the time of the write for an event that happened before it' do
      expect(described_class.arrival(at: now - 2.days)).to eq(now)
    end

    it 'answers the event\'s own time for an event that lies after the time of the write' do
      expect(described_class.arrival(at: now + 2.minutes)).to eq(now + 2.minutes)
    end

    it 'answers the time of the write for an event at that very moment' do
      expect(described_class.arrival(at: now)).to eq(now)
    end

    it 'answers the time of the write for an event without a time of its own' do
      expect(described_class.arrival(at: nil)).to eq(now)
    end

    it 'reads the clock on every call' do
      expect(described_class.arrival(at: nil)).to eq(now)

      travel_to(now + 1.minute)

      expect(described_class.arrival(at: nil)).to eq(now + 1.minute)
      expect(described_class.arrival(at: now)).to eq(now + 1.minute)
    end
  end

  describe '.fold!' do
    include ActiveSupport::Testing::TimeHelpers

    # Every time of a row is its own, and the events of a call lie before,
    # inside and after its span. The factory copies created_at into both event
    # times, which would hide a span that moves the wrong end. The clock stands
    # at `now`, after all of them: a fold writes last_event_at as the arrival of
    # the event, the time of the write, and first_event_at from the event's own
    # time. Two times lie after the clock, for an event and for a row ahead of it.
    let(:earlier_time) { Time.zone.local(2026, 11, 24, 14, 0, 0) }
    let(:first_time) { Time.zone.local(2026, 11, 24, 14, 1, 0) }
    let(:created_time) { Time.zone.local(2026, 11, 24, 14, 1, 30) }
    let(:inside_time) { Time.zone.local(2026, 11, 24, 14, 2, 0) }
    let(:last_time) { Time.zone.local(2026, 11, 24, 14, 3, 0) }
    let(:later_time) { Time.zone.local(2026, 11, 24, 14, 4, 0) }
    let(:written_time) { Time.zone.local(2026, 11, 24, 14, 5, 0) }
    let(:now) { Time.zone.local(2026, 11, 24, 14, 10, 0) }
    let(:ahead_time) { Time.zone.local(2026, 11, 24, 14, 12, 0) }
    let(:far_ahead_time) { Time.zone.local(2026, 11, 24, 14, 20, 0) }
    let(:first_post_id) { SecureRandom.uuid }
    let(:second_post_id) { SecureRandom.uuid }
    let(:kept_columns) do
      %w[group_count first_event_at last_event_at happened_at payload actor_id updated_at state read_at
         archived_at created_at]
    end

    before { travel_to(now) }
    after { travel_back }

    def create_row(**attributes)
      defaults = {
        recipient: recipient, organisation: organisation, notifiable: ticket, project: project,
        group_key: 'ticket:commented:20261124-1400', group_count: 1, event_type: 'ticket_commented',
        channel: 'in_app', state: 'queued', priority: 'normal', actor: actor,
        payload: { 'action' => 'commented', 'actor_ids' => [actor.id] },
        created_at: created_time, updated_at: written_time,
        first_event_at: first_time, last_event_at: last_time
      }
      create(:notification, **defaults.merge(attributes))
    end

    # The columns a fold writes or must leave alone, read from the database
    # without touching the object the example hands to fold!.
    def row_values(row)
      Notification.find(row.id).attributes.slice(*kept_columns)
    end

    it 'raises the count by one' do
      row = create_row(group_count: 3)
      expect(row_values(row)).to include('group_count' => 3)

      described_class.fold!(notification: row, at: later_time)

      expect(row_values(row)).to include('group_count' => 4)
    end

    it 'moves last_event_at to the time of the write for a later event and leaves first_event_at' do
      row = create_row
      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => last_time,
                                         'created_at' => created_time)

      described_class.fold!(notification: row, at: later_time)

      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => now,
                                         'created_at' => created_time)
    end

    it 'moves first_event_at back to an earlier event and last_event_at to the time of the write' do
      row = create_row
      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => last_time,
                                         'created_at' => created_time)

      described_class.fold!(notification: row, at: earlier_time)

      expect(row_values(row)).to include('first_event_at' => earlier_time, 'last_event_at' => now,
                                         'created_at' => created_time)
    end

    it 'leaves first_event_at and moves last_event_at to the time of the write for an event inside the span' do
      row = create_row
      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => last_time)

      described_class.fold!(notification: row, at: inside_time)

      expect(row_values(row)).to include('group_count' => 2, 'first_event_at' => first_time,
                                         'last_event_at' => now)
    end

    # The two bounds of the right edge: never before the event's own time, and
    # never back behind what the row already holds.
    it 'moves last_event_at to the event\'s own time when that lies after the time of the write' do
      row = create_row
      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => last_time)
      expect(ahead_time).to be > now

      described_class.fold!(notification: row, at: ahead_time)

      expect(row_values(row)).to include('group_count' => 2, 'first_event_at' => first_time,
                                         'last_event_at' => ahead_time)
    end

    it 'keeps the last_event_at of a row that lies after the event and after the time of the write' do
      row = create_row(last_event_at: far_ahead_time)
      expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => far_ahead_time)
      expect(far_ahead_time).to be > now
      expect(far_ahead_time).to be > ahead_time

      described_class.fold!(notification: row, at: ahead_time)

      expect(row_values(row)).to include('group_count' => 2, 'first_event_at' => first_time,
                                         'last_event_at' => far_ahead_time)
    end

    # An event without a time of its own has arrived now: the count rises, the
    # left edge stays, the right edge is the time of the write.
    it 'folds an event without a time of its own: last_event_at is the time of the write' do
      row = create_row(group_count: 3)
      expect(row_values(row)).to include('group_count' => 3, 'first_event_at' => first_time,
                                         'last_event_at' => last_time)

      answer = described_class.fold!(notification: row, at: nil)

      expect(answer).to be(true)
      expect(row_values(row)).to include('group_count' => 4, 'first_event_at' => first_time,
                                         'last_event_at' => now, 'created_at' => created_time)
    end

    # Two folds are two writes: the row stands at the later one.
    it 'moves last_event_at again when a second event folds in later' do
      row = create_row

      described_class.fold!(notification: row, at: earlier_time)
      expect(row_values(row)).to include('group_count' => 2, 'last_event_at' => now)

      travel_to(now + 1.minute)
      described_class.fold!(notification: Notification.find(row.id), at: inside_time)

      expect(row_values(row)).to include('group_count' => 3, 'first_event_at' => earlier_time,
                                         'last_event_at' => now + 1.minute)
    end

    # happened_at is the latest event's own time, the time a row shows: it widens
    # like the span and never takes the time of the write. The rows above carry
    # none (written before the column), the rows here carry last_time.
    describe 'happened_at' do
      it 'moves to the own time of a later event, where last_event_at takes the time of the write' do
        row = create_row(happened_at: last_time)

        described_class.fold!(notification: row, at: later_time)

        expect(row_values(row)).to include('first_event_at' => first_time, 'happened_at' => later_time,
                                           'last_event_at' => now)
      end

      it 'stays for an earlier event and for one inside the span' do
        row = create_row(happened_at: last_time)

        described_class.fold!(notification: row, at: earlier_time)
        described_class.fold!(notification: Notification.find(row.id), at: inside_time)

        expect(row_values(row)).to include('group_count' => 3, 'first_event_at' => earlier_time,
                                           'happened_at' => last_time, 'last_event_at' => now)
      end

      it 'stays for an event without a time of its own' do
        row = create_row(happened_at: last_time)

        described_class.fold!(notification: row, at: nil)

        expect(row_values(row)).to include('group_count' => 2, 'happened_at' => last_time, 'last_event_at' => now)
      end

      # Before the column last_event_at was the event's own time: a fold starts from it.
      it 'starts from last_event_at on a row written before the column' do
        row = create_row
        expect(row_values(row)).to include('happened_at' => nil, 'last_event_at' => last_time)
        expect(row.happened_at).to eq(last_time)

        described_class.fold!(notification: row, at: earlier_time)

        expect(row_values(row)).to include('first_event_at' => earlier_time, 'happened_at' => last_time,
                                           'last_event_at' => now)
      end
    end

    # The row's line (actor_id and the payload's single values: activity_id,
    # action, parameters) names the event at happened_at, the time the row shows.
    # An earlier event that folds in late (a retried outbox event) joins the row
    # with its count, its actor and its lists, and leaves the line to the later
    # event: its actor goes before the leading one in actor_ids, which stays
    # last. An event at the time of the latest one leads; one without a time of
    # its own does not, since happened_at stays.
    describe 'the line of the row' do
      let(:leading_payload) do
        { 'action' => 'commented', 'activity_id' => 'later-activity', 'parameters' => { 'excerpt' => 'later' },
          'actor_ids' => [actor.id], 'post_ids' => [first_post_id] }
      end

      it 'stays with the later event when an earlier one folds in late' do
        row = create_row(happened_at: last_time, payload: leading_payload)

        described_class.fold!(notification: row, at: earlier_time, actor_id: other_actor.id,
                              payload: { 'action' => 'mentioned', 'activity_id' => 'earlier-activity',
                                         'parameters' => { 'excerpt' => 'earlier' }, 'post_ids' => [second_post_id] })

        values = row_values(row)
        expect(values).to include('group_count' => 2, 'actor_id' => actor.id, 'happened_at' => last_time,
                                  'first_event_at' => earlier_time)
        expect(values['payload']).to eq('action' => 'commented', 'activity_id' => 'later-activity',
                                        'parameters' => { 'excerpt' => 'later' },
                                        'actor_ids' => [other_actor.id, actor.id],
                                        'post_ids' => [first_post_id, second_post_id])
      end

      it 'goes to an event at the time of the latest one' do
        row = create_row(happened_at: last_time, payload: leading_payload)

        described_class.fold!(notification: row, at: last_time, actor_id: other_actor.id,
                              payload: { 'activity_id' => 'same-time-activity' })

        values = row_values(row)
        expect(values['actor_id']).to eq(other_actor.id)
        expect(values['payload']).to include('activity_id' => 'same-time-activity',
                                             'actor_ids' => [actor.id, other_actor.id])
      end

      it 'stays for an event without a time of its own' do
        row = create_row(happened_at: last_time, payload: leading_payload)

        described_class.fold!(notification: row, at: nil, actor_id: other_actor.id,
                              payload: { 'activity_id' => 'timeless-activity' })

        values = row_values(row)
        expect(values['actor_id']).to eq(actor.id)
        expect(values['payload']).to include('activity_id' => 'later-activity',
                                             'actor_ids' => [other_actor.id, actor.id])
      end

      it 'takes a single value the row lacks, also from an earlier event' do
        row = create_row(happened_at: last_time, payload: { 'action' => 'commented', 'actor_ids' => [actor.id] })

        described_class.fold!(notification: row, at: earlier_time, payload: { 'activity_id' => 'earlier-activity' })

        expect(row_values(row)['payload']).to include('activity_id' => 'earlier-activity', 'action' => 'commented')
      end

      # The activities popover reads actor_ids from the end, the leading actor first.
      it 'puts an actor who leads again at the end of actor_ids' do
        row = create_row(happened_at: last_time)
        described_class.fold!(notification: row, at: later_time, actor_id: other_actor.id)

        described_class.fold!(notification: Notification.find(row.id), at: later_time + 30.seconds, actor_id: actor.id)

        values = row_values(row)
        expect(values['actor_id']).to eq(actor.id)
        expect(values['payload']['actor_ids']).to eq([other_actor.id, actor.id])
      end
    end

    it 'writes the new actor to actor_id and keeps both actors once in actor_ids' do
      row = create_row
      expect(row_values(row)).to include('actor_id' => actor.id,
                                         'payload' => { 'action' => 'commented', 'actor_ids' => [actor.id] })

      described_class.fold!(notification: row, at: later_time, actor_id: other_actor.id)

      values = row_values(row)
      expect(values['actor_id']).to eq(other_actor.id)
      expect(values['payload']['actor_ids']).to eq([actor.id, other_actor.id])
    end

    # The builder merged the actors also when the event brought none: the row's
    # actor still lands in actor_ids, and actor_id stays.
    it 'keeps the row\'s actor and lists it in actor_ids when the event brings none' do
      row = create_row(payload: { 'action' => 'commented', 'actor_ids' => [] })
      expect(row_values(row)).to include('actor_id' => actor.id,
                                         'payload' => { 'action' => 'commented', 'actor_ids' => [] })

      described_class.fold!(notification: row, at: later_time)

      values = row_values(row)
      expect(values['actor_id']).to eq(actor.id)
      expect(values['payload']['actor_ids']).to eq([actor.id])
    end

    it 'merges the payload' do
      row = create_row(payload: { 'action' => 'commented', 'actor_ids' => [actor.id],
                                  'post_ids' => [first_post_id], 'message' => 'First comment' })

      described_class.fold!(notification: row, at: later_time,
                            payload: { post_ids: [second_post_id], 'message' => 'Second comment' })

      expect(row_values(row)['payload']).to eq('action' => 'commented', 'actor_ids' => [actor.id],
                                               'post_ids' => [first_post_id, second_post_id],
                                               'message' => 'Second comment')
    end

    # The actor is merged before the payload, as it was in the builder: actor
    # ids that the payload itself brings come after the row's and the new actor.
    it 'merges the actor before the payload' do
      row = create_row
      third_actor_id = SecureRandom.uuid
      expect(row_values(row)['payload']['actor_ids']).to eq([actor.id])

      described_class.fold!(notification: row, at: later_time, actor_id: other_actor.id,
                            payload: { 'actor_ids' => [third_actor_id] })

      expect(row_values(row)['payload']['actor_ids']).to eq([actor.id, other_actor.id, third_actor_id])
    end

    it 'answers true and saves the row' do
      row = create_row

      answer = described_class.fold!(notification: row, at: later_time)

      expect(answer).to be(true)
      expect(row).not_to be_changed
      expect(row_values(row)).to include('group_count' => 2, 'last_event_at' => now, 'updated_at' => now)
    end

    it 'folds without a block' do
      row = create_row

      expect(described_class.fold!(notification: row, at: later_time)).to be(true)

      expect(row_values(row)).to include('group_count' => 2, 'last_event_at' => now)
    end

    context 'when the row is read or archived' do
      it 'refuses a read row and writes nothing' do
        row = create_row(state: 'read', read_at: written_time)
        before_call = row_values(row)
        expect(before_call).to include('state' => 'read', 'read_at' => written_time, 'group_count' => 1,
                                       'first_event_at' => first_time, 'last_event_at' => last_time,
                                       'actor_id' => actor.id, 'updated_at' => written_time,
                                       'payload' => { 'action' => 'commented', 'actor_ids' => [actor.id] })

        answer = described_class.fold!(notification: row, at: later_time, actor_id: other_actor.id,
                                       payload: { 'message' => 'Second comment' })

        expect(answer).to be(false)
        expect(row_values(row)).to eq(before_call)
      end

      it 'refuses an archived row and writes nothing' do
        row = create_row(state: 'archived', read_at: written_time, archived_at: written_time)
        before_call = row_values(row)
        expect(before_call).to include('state' => 'archived', 'archived_at' => written_time, 'group_count' => 1,
                                       'first_event_at' => first_time, 'last_event_at' => last_time,
                                       'actor_id' => actor.id, 'updated_at' => written_time,
                                       'payload' => { 'action' => 'commented', 'actor_ids' => [actor.id] })

        answer = described_class.fold!(notification: row, at: earlier_time, actor_id: other_actor.id,
                                       payload: { 'message' => 'Second comment' })

        expect(answer).to be(false)
        expect(row_values(row)).to eq(before_call)
      end
    end

    context 'when the row was loaded unread and read in the database afterwards' do
      it 'refuses the fold and writes nothing' do
        row = create_row
        loaded = Notification.find(row.id)
        Notification.where(id: row.id).update_all(state: 'read', read_at: now)
        expect(loaded).to have_attributes(state: 'queued', read_at: nil)
        before_call = row_values(row)
        expect(before_call).to include('state' => 'read', 'read_at' => now, 'group_count' => 1,
                                       'first_event_at' => first_time, 'last_event_at' => last_time,
                                       'updated_at' => written_time)

        answer = described_class.fold!(notification: loaded, at: later_time, actor_id: other_actor.id)

        expect(answer).to be(false)
        expect(loaded).to have_attributes(state: 'read', read_at: now)
        expect(row_values(row)).to eq(before_call)
      end

      it 'does not ask the block' do
        row = create_row
        loaded = Notification.find(row.id)
        Notification.where(id: row.id).update_all(state: 'read', read_at: now)
        expect(loaded).to have_attributes(state: 'queued', read_at: nil)
        before_call = row_values(row)
        expect(before_call).to include('state' => 'read', 'group_count' => 1, 'last_event_at' => last_time)

        asked = []
        answer = described_class.fold!(notification: loaded, at: later_time) do |given|
          asked << given.state
          true
        end

        expect(answer).to be(false)
        expect(asked).to be_empty
        expect(row_values(row)).to eq(before_call)
      end
    end

    context 'with a block' do
      it 'hands the block the row as the database holds it under the lock' do
        row = create_row
        loaded = Notification.find(row.id)
        Notification.where(id: row.id).update_all(group_count: 4, priority: 'low')
        expect(loaded).to have_attributes(group_count: 1, priority: 'normal')

        seen = []
        answer = described_class.fold!(notification: loaded, at: later_time) do |given|
          seen << [given, given.group_count, given.priority]
          true
        end

        expect(answer).to be(true)
        expect(seen.size).to eq(1)
        expect(seen.first.first).to be(loaded)
        expect(seen.first.drop(1)).to eq([4, 'low'])
        expect(row_values(row)).to include('group_count' => 5, 'last_event_at' => now)
      end

      it 'stops the fold and writes nothing when the block answers false' do
        row = create_row
        before_call = row_values(row)
        expect(before_call).to include('group_count' => 1, 'first_event_at' => first_time,
                                       'last_event_at' => last_time, 'actor_id' => actor.id,
                                       'updated_at' => written_time,
                                       'payload' => { 'action' => 'commented', 'actor_ids' => [actor.id] })

        asked = 0
        answer = described_class.fold!(notification: row, at: later_time, actor_id: other_actor.id,
                                       payload: { 'message' => 'Second comment' }) do
          asked += 1
          false
        end

        expect(answer).to be(false)
        expect(asked).to eq(1)
        expect(row_values(row)).to eq(before_call)
      end

      it 'stops the fold when the block answers nil' do
        row = create_row
        before_call = row_values(row)
        expect(before_call).to include('group_count' => 1, 'last_event_at' => last_time)

        answer = described_class.fold!(notification: row, at: later_time) { nil }

        expect(answer).to be(false)
        expect(row_values(row)).to eq(before_call)
      end

      it 'folds when the block answers true' do
        row = create_row

        answer = described_class.fold!(notification: row, at: later_time) { true }

        expect(answer).to be(true)
        expect(row_values(row)).to include('group_count' => 2, 'last_event_at' => now)
      end
    end

    context 'when it saves' do
      around { |example| with_test_queue_adapter { example.run } }

      it 'runs the validations: an invalid row raises and writes nothing' do
        row = create_row
        Notification.where(id: row.id).update_all(score: 101)
        before_call = row_values(row)
        expect(before_call).to include('group_count' => 1, 'last_event_at' => last_time,
                                       'updated_at' => written_time)

        expect { described_class.fold!(notification: row, at: later_time) }
          .to raise_error(ActiveRecord::RecordInvalid) { |error| expect(error.record.errors.attribute_names).to eq([:score]) }

        expect(row_values(row)).to eq(before_call)
      end

      it 'runs the callbacks: the unread signal of the recipient is refreshed' do
        row = create_row
        clear_enqueued_jobs

        expect { described_class.fold!(notification: row, at: later_time) }
          .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: recipient.id)
      end

      # An earlier event moves the row up as well, so the lists must hear of it.
      it 'refreshes the unread signal of the recipient for an event earlier than the row\'s first' do
        row = create_row
        clear_enqueued_jobs
        expect(row_values(row)).to include('first_event_at' => first_time, 'last_event_at' => last_time)
        expect(earlier_time).to be < first_time

        expect { described_class.fold!(notification: row, at: earlier_time) }
          .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: recipient.id)
      end

      # The clock stands before the row's last_event_at, and the event is not later
      # than its happened_at: neither time moves, only the count. The lists must
      # hear of it all the same.
      it 'refreshes the unread signal of the recipient when only the count moves' do
        row = create_row(happened_at: last_time, last_event_at: far_ahead_time)
        clear_enqueued_jobs
        expect(row_values(row)).to include('group_count' => 1, 'first_event_at' => first_time,
                                           'happened_at' => last_time, 'last_event_at' => far_ahead_time)
        expect(far_ahead_time).to be > now
        expect(inside_time).to be_between(first_time, last_time)

        expect { described_class.fold!(notification: row, at: inside_time) }
          .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: recipient.id)

        expect(row_values(row)).to include('group_count' => 2, 'first_event_at' => first_time,
                                           'happened_at' => last_time, 'last_event_at' => far_ahead_time)
      end

      it 'moves updated_at to the time of the fold' do
        row = create_row
        expect(row_values(row)).to include('updated_at' => written_time)

        described_class.fold!(notification: row, at: earlier_time)

        expect(row_values(row)).to include('group_count' => 2, 'updated_at' => now)
      end
    end
  end

  # A row the fanout wrote and read at once, its comment acknowledged before it
  # arrived: it stands at the time its event happened, not at its write
  # (FanoutService#reconcile_existing_post_reads; the chain in
  # fanout_service_ticket_simple_spec.rb).
  describe '.acknowledged_on_arrival!' do
    it 'stands the row at the time its latest event happened and leaves the other event fields' do
      event_time = 2.hours.ago.change(usec: 0)
      row = create(:notification, recipient: recipient, organisation: organisation, notifiable: ticket,
                                  project: project, event_type: 'ticket_commented', channel: 'in_app',
                                  state: 'read', read_at: Time.current, created_at: Time.current,
                                  first_event_at: event_time, happened_at: event_time, last_event_at: Time.current)

      described_class.acknowledged_on_arrival!(notification: row)

      expect(Notification.find(row.id).attributes.slice(*%w[group_count first_event_at happened_at last_event_at]))
        .to eq('group_count' => 1, 'first_event_at' => event_time, 'happened_at' => event_time,
               'last_event_at' => event_time)
    end
  end

  # The two merges a fold makes, one by one. Moved here with the methods from
  # the builder's spec, inputs and expectations unchanged.
  describe 'private helpers' do
    describe '.merge_payload' do
      let(:notification) { Notification.new(payload: { 'tags' => %w[a b], 'status' => 'open' }) }

      it 'merges two arrays by concatenation and deduplication' do
        described_class.send(:merge_payload, notification, { 'tags' => %w[b c] })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'appends a scalar to an existing array' do
        described_class.send(:merge_payload, notification, { 'tags' => 'c' })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'prepends existing scalar to a new array' do
        described_class.send(:merge_payload, notification, { 'status' => %w[closed archived] })
        expect(notification.payload['status']).to eq(%w[open closed archived])
      end

      it 'overwrites scalar with latest scalar' do
        described_class.send(:merge_payload, notification, { 'status' => 'closed' })
        expect(notification.payload['status']).to eq('closed')
      end

      it 'adds new keys that did not exist before' do
        described_class.send(:merge_payload, notification, { 'new_key' => 'new_value' })
        expect(notification.payload['new_key']).to eq('new_value')
      end

      it 'handles nil new_payload gracefully' do
        expect { described_class.send(:merge_payload, notification, nil) }.not_to raise_error
        expect(notification.payload).to eq({ 'tags' => %w[a b], 'status' => 'open' })
      end

      it 'handles nil existing payload' do
        notification.payload = nil
        described_class.send(:merge_payload, notification, { 'key' => 'val' })
        expect(notification.payload['key']).to eq('val')
      end

      it 'deduplicates when merging arrays' do
        described_class.send(:merge_payload, notification, { 'tags' => %w[a a b c c] })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'merges symbol-keyed arrays into persisted string-keyed payloads' do
        notification.payload = { 'post_ids' => ['post-1'] }

        described_class.send(:merge_payload, notification, { post_ids: ['post-2'] })

        expect(notification.payload['post_ids']).to contain_exactly('post-1', 'post-2')
      end

      it 'compacts nil values when prepending scalar to array' do
        notification.payload['nullable'] = nil
        described_class.send(:merge_payload, notification, { 'nullable' => %w[x y] })
        expect(notification.payload['nullable']).to eq(%w[x y])
      end
    end

    describe '.merge_actors' do
      let(:notification) do
        Notification.new(
          actor_id: actor.id,
          payload: { 'actor_ids' => [] }
        )
      end

      it 'adds the existing actor_id and the new actor_id' do
        described_class.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to contain_exactly(actor.id, other_actor.id)
      end

      it 'updates actor_id to the new actor' do
        described_class.send(:merge_actors, notification, other_actor.id)
        expect(notification.actor_id).to eq(other_actor.id)
      end

      it 'deduplicates actor ids' do
        described_class.send(:merge_actors, notification, actor.id)
        expect(notification.payload['actor_ids']).to eq([actor.id])
      end

      it 'handles nil new_actor_id' do
        described_class.send(:merge_actors, notification, nil)
        expect(notification.payload['actor_ids']).to eq([actor.id])
        expect(notification.actor_id).to eq(actor.id)
      end

      it 'handles nil existing actor_id' do
        notification.actor_id = nil
        described_class.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to eq([other_actor.id])
      end

      it 'handles missing actor_ids key in payload' do
        notification.payload = {}
        described_class.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to contain_exactly(actor.id, other_actor.id)
      end
    end
  end
end
