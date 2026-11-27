# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::GroupKeyBuilder do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:actor) { create(:user) }
  let(:other_actor) { create(:user) }
  let(:recipient) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:activity) do
    create(:activity,
           actor: actor,
           organisation: organisation,
           trackable: ticket,
           action: 'ticket_commented',
           key: 'ticket.ticket_commented')
  end

  subject(:builder) { described_class.new(activity, recipient) }

  before { ActsAsTenant.current_tenant = organisation }

  # ---------------------------------------------------------------------------
  # #build
  # ---------------------------------------------------------------------------
  describe '#build' do
    it 'joins trackable class, id, normalized action, and time bucket' do
      key = builder.build
      parts = key.split(':')

      expect(parts.size).to eq(4)
      expect(parts[0]).to eq('ticket')
      expect(parts[1]).to eq(ticket.id.to_s)
      expect(parts[2]).to eq('commented') # ticket_commented contains 'comment'
      expect(parts[3]).to match(/\A\d{8}-\d{4}\z/)
    end

    it 'is deterministic for the same activity' do
      expect(builder.build).to eq(builder.build)
    end

    context 'with nil trackable' do
      let(:activity) do
        instance_double(Activity,
                        trackable: nil,
                        action: 'system_event',
                        created_at: Time.current,
                        id: SecureRandom.uuid)
      end

      it 'omits nil components and avoids consecutive colons' do
        key = builder.build
        expect(key).not_to include('::')
        expect(key).to match(/\Asystem_event:\d{8}-\d{4}\z/)
      end
    end

    # --- Action normalization ------------------------------------------------
    describe 'action normalization' do
      using_doubles = {
        'comment' => 'commented',
        'reply' => 'commented',
        'post_added' => 'commented',
        'new_comment' => 'commented',
        'status_changed' => 'status_changed',
        'state_update' => 'status_changed',
        'transition' => 'status_changed',
        'assigned' => 'assigned',
        'reassigned' => 'assigned',
        'attachment_added' => 'document_added',
        'upload_file' => 'document_added',
        'document_created' => 'document_added',
        'custom_action' => 'custom_action',
        'UPPER_CASE' => 'upper_case',
        'special-chars!' => 'special_chars_'
      }

      using_doubles.each do |input, expected|
        it "normalizes '#{input}' to '#{expected}'" do
          act = instance_double(Activity,
                                trackable: ticket,
                                action: input,
                                created_at: Time.current,
                                id: SecureRandom.uuid)
          b = described_class.new(act, recipient)

          expect(b.build.split(':')[2]).to eq(expected)
        end
      end

      it 'converts Symbol actions to string' do
        act = instance_double(Activity,
                              trackable: ticket,
                              action: :commented,
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)

        expect(b.build.split(':')[2]).to eq('commented')
      end
    end

    # --- Time bucketing ------------------------------------------------------
    describe 'time bucketing' do
      it 'produces the same bucket for two timestamps in the same 5-minute window' do
        t1 = Time.new(2024, 1, 15, 14, 0, 0)
        t2 = Time.new(2024, 1, 15, 14, 4, 59)

        a1 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t1, id: SecureRandom.uuid)
        a2 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t2, id: SecureRandom.uuid)

        expect(described_class.new(a1, recipient).build).to eq(described_class.new(a2, recipient).build)
      end

      it 'produces different buckets at the 5-minute boundary' do
        t1 = Time.new(2024, 1, 15, 14, 4, 59)
        t2 = Time.new(2024, 1, 15, 14, 5, 0)

        a1 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t1, id: SecureRandom.uuid)
        a2 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t2, id: SecureRandom.uuid)

        expect(described_class.new(a1, recipient).build).not_to eq(described_class.new(a2, recipient).build)
      end

      it 'produces different buckets for activities far apart' do
        t1 = Time.new(2024, 1, 15, 14, 0, 0)
        t2 = Time.new(2024, 1, 15, 15, 0, 0) # 1 hour later

        a1 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t1, id: SecureRandom.uuid)
        a2 = instance_double(Activity, trackable: ticket, action: 'created', created_at: t2, id: SecureRandom.uuid)

        expect(described_class.new(a1, recipient).build).not_to eq(described_class.new(a2, recipient).build)
      end
    end

    # --- Different trackable types -------------------------------------------
    describe 'trackable type in key' do
      it 'uses the correct underscored class name' do
        doc = create(:document, project: project, organisation: organisation)
        act = instance_double(Activity,
                              trackable: doc,
                              action: 'created',
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)

        expect(b.build).to start_with('document:')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #find_or_create_group
  # ---------------------------------------------------------------------------
  describe '#find_or_create_group' do
    include ActiveSupport::Testing::TimeHelpers

    let(:notification_params) do
      {
        recipient_id: recipient.id,
        actor_id: actor.id,
        notifiable_type: 'Ticket',
        notifiable_id: ticket.id,
        event_type: 'ticket_commented',
        channel: 'in_app',
        payload: { 'action' => 'commented', 'message' => 'Test comment' },
        organisation_id: organisation.id
      }
    end

    # --- Creating a new group ------------------------------------------------
    context 'when no existing group exists' do
      it 'creates a new notification' do
        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'sets the group_key from build' do
        notification = builder.find_or_create_group(notification_params)
        expect(notification.group_key).to eq(builder.build)
      end

      it 'sets group_count to 1' do
        notification = builder.find_or_create_group(notification_params)
        expect(notification.group_count).to eq(1)
      end

      it 'sets first_event_at from the activity and last_event_at to the time of the write' do
        written_at = activity.created_at.change(usec: 0) + 2.minutes
        travel_to(written_at) do
          notification = builder.find_or_create_group(notification_params)
          expect(notification.first_event_at).to eq(activity.created_at)
          expect(notification.last_event_at).to eq(written_at)
        end
      end

      it 'generates a dedupe_fingerprint' do
        notification = builder.find_or_create_group(notification_params)
        expect(notification.dedupe_fingerprint).to be_present
        expect(notification.dedupe_fingerprint.length).to eq(64) # SHA256 hex
      end

      it 'determines the project from a Ticket trackable' do
        notification = builder.find_or_create_group(notification_params)
        expect(notification.project).to eq(project)
      end

      it 'determines the project from a Project trackable' do
        act = create(:activity,
                     actor: actor,
                     organisation: organisation,
                     trackable: project,
                     action: 'created',
                     key: 'project.created')
        b = described_class.new(act, recipient)
        params = notification_params.merge(
          notifiable_type: 'Project',
          notifiable_id: project.id,
          event_type: 'project_announcement'
        )

        notification = b.find_or_create_group(params)
        expect(notification.project).to eq(project)
      end

      it 'sets project to nil when trackable has no project association' do
        act = instance_double(Activity,
                              trackable: nil,
                              action: 'system_event',
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)
        params = notification_params.merge(
          notifiable_type: 'Ticket',
          event_type: 'system_message'
        )

        notification = b.find_or_create_group(params)
        expect(notification.project).to be_nil
      end
    end

    # --- A row written later than its activity --------------------------------
    # The fanout can write a row long after its activity (an outbox event that
    # was delayed or retried). The row then stands at the moment the event
    # reached it, the time of the write, where every list reads it, and keeps
    # the activity's own time as its first event. It never stands before its
    # activity. The clock stands still and lies apart from both activities.
    context 'when the row is written at another time than its activity' do
      let(:now) { Time.zone.local(2026, 11, 24, 14, 10, 0) }
      let(:activity) do
        create(:activity, actor: actor, organisation: organisation, trackable: ticket,
                          action: 'ticket_commented', key: 'ticket.ticket_commented',
                          created_at: now - 2.days)
      end

      before { travel_to(now) }
      after { travel_back }

      it 'stamps a row written two days after its activity with the time of the write' do
        expect(activity.created_at).to eq(now - 2.days)

        notification = builder.find_or_create_group(notification_params)

        expect(Notification.find(notification.id))
          .to have_attributes(group_count: 1, first_event_at: now - 2.days, last_event_at: now, created_at: now)
      end

      # What the row shows is when its event happened, not when it reached the row.
      it 'keeps the activity\'s own time as the time the row shows' do
        notification = builder.find_or_create_group(notification_params)

        row = Notification.find(notification.id)
        expect(row.read_attribute(:happened_at)).to eq(now - 2.days)
        expect(row.happened_at).to eq(now - 2.days)
      end

      # The builder holds no copy of the rule. It asks the owner, and what the
      # owner answers is what the row gets. The answer here lies before the
      # activity and before the clock: a maximum the builder took on its own
      # with either of them would write another time.
      it 'takes the latest event of a new row from RowEvents.arrival' do
        answer = now - 3.days
        allow(Notifications::RowEvents).to receive(:arrival).and_call_original
        allow(Notifications::RowEvents).to receive(:arrival).with(at: activity.created_at).and_return(answer)

        notification = builder.find_or_create_group(notification_params)

        expect(Notifications::RowEvents).to have_received(:arrival).with(at: activity.created_at).once
        expect(Notification.find(notification.id))
          .to have_attributes(group_count: 1, first_event_at: now - 2.days, last_event_at: answer,
                              happened_at: now - 2.days)
      end

      it 'stamps an email row the same way' do
        notification = builder.find_or_create_group(notification_params.merge(channel: 'email'))

        expect(Notification.find(notification.id))
          .to have_attributes(channel: 'email', first_event_at: now - 2.days, last_event_at: now, created_at: now)
      end

      it 'stamps a row with its activity\'s time when that lies after the time of the write' do
        ahead = create(:activity, actor: actor, organisation: organisation, trackable: ticket,
                                  action: 'ticket_commented', key: 'ticket.ticket_commented',
                                  created_at: now + 2.minutes)

        notification = described_class.new(ahead, recipient).find_or_create_group(notification_params)

        expect(Notification.find(notification.id))
          .to have_attributes(group_count: 1, first_event_at: now + 2.minutes, last_event_at: now + 2.minutes,
                              happened_at: now + 2.minutes, created_at: now)
      end
    end

    # --- Updating an existing group ------------------------------------------
    context 'when a compatible existing group exists' do
      let!(:existing_notification) do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented', 'actor_ids' => [] })
      end

      it 'does not create a new notification' do
        expect { builder.find_or_create_group(notification_params) }
          .not_to change(Notification, :count)
      end

      it 'increments group_count' do
        builder.find_or_create_group(notification_params)
        expect(existing_notification.reload.group_count).to eq(2)
      end

      it 'updates last_event_at to the time of the write' do
        written_at = activity.created_at.change(usec: 0) + 2.minutes
        travel_to(written_at) { builder.find_or_create_group(notification_params) }
        expect(existing_notification.reload.last_event_at).to eq(written_at)
      end

      it 'merges the new actor into payload actor_ids' do
        params = notification_params.merge(actor_id: other_actor.id)
        builder.find_or_create_group(params)

        reloaded = existing_notification.reload
        expect(reloaded.payload['actor_ids']).to include(other_actor.id)
      end

      it 'updates actor_id to the latest actor' do
        params = notification_params.merge(actor_id: other_actor.id)
        builder.find_or_create_group(params)

        expect(existing_notification.reload.actor_id).to eq(other_actor.id)
      end

      it 'merges payload data' do
        params = notification_params.merge(payload: { 'message' => 'Updated comment' })
        builder.find_or_create_group(params)

        expect(existing_notification.reload.payload['message']).to eq('Updated comment')
      end

      # Two activities of the same five minutes can reach the fanout out of order (a
      # retried outbox event). The later one made the row; the earlier one folds in.
      # The row's span of events only ever widens: its first event moves back to
      # the earlier activity, and its latest event is the moment that activity
      # reached the row, the time of the write. The lists order and print by
      # last_event_at (Notification.recent), so the row moves up, and
      # Posts::MarkRead matches a comment by first_event_at..last_event_at.
      context 'when an earlier activity of the same bucket folds in after a later one' do
        include ActiveSupport::Testing::TimeHelpers

        let(:bucket_start) { Time.zone.local(2026, 11, 24, 14, 0, 0) }
        let(:earlier) do
          create(:activity, actor: actor, organisation: organisation, trackable: ticket,
                            action: 'ticket_commented', key: 'ticket.ticket_commented',
                            created_at: bucket_start + 30.seconds)
        end
        let!(:row_of_later) do
          create(:notification,
                 recipient: recipient, organisation: organisation, notifiable: ticket,
                 group_key: described_class.new(earlier, recipient).build, group_count: 1,
                 event_type: 'ticket_commented', state: 'queued', priority: 'normal', actor: actor,
                 payload: { 'action' => 'commented', 'actor_ids' => [] },
                 created_at: bucket_start + 3.minutes, first_event_at: bucket_start + 3.minutes,
                 happened_at: bucket_start + 3.minutes, last_event_at: bucket_start + 3.minutes)
        end

        before { travel_to(bucket_start + 4.minutes) }
        after { travel_back }

        it 'folds into the row and moves its latest event to the time of the write' do
          described_class.new(earlier, recipient).find_or_create_group(notification_params)

          row_of_later.reload
          expect(row_of_later.group_count).to eq(2)
          expect(row_of_later.last_event_at).to eq(bucket_start + 4.minutes)
        end

        it 'keeps the later activity as the time the row shows' do
          described_class.new(earlier, recipient).find_or_create_group(notification_params)

          expect(row_of_later.reload.happened_at).to eq(bucket_start + 3.minutes)
        end

        it 'moves its first event back to the earlier activity' do
          described_class.new(earlier, recipient).find_or_create_group(notification_params)

          expect(row_of_later.reload.first_event_at).to eq(bucket_start + 30.seconds)
        end
      end

      context 'when existing notification was read' do
        let!(:existing_notification) do
          create(:notification,
                 recipient: recipient,
                 organisation: organisation,
                 group_key: builder.build,
                 group_count: 1,
                 notifiable: ticket,
                 event_type: 'ticket_commented',
                 state: 'read',
                 priority: 'normal',
                 created_at: 1.minute.ago,
                 read_at: 30.seconds.ago,
                 actor: actor,
                 payload: { 'action' => 'commented' })
        end

        it 'creates a new notification instead of updating the read one' do
          expect { builder.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
        end
      end
    end

    # --- Edge cases that force new group creation ----------------------------
    describe 'creates a new group when' do
      it 'the existing group was archived' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'archived',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'an email group has already been sent' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               channel: 'email',
               state: 'sent',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        params = notification_params.merge(channel: 'email')

        expect { builder.find_or_create_group(params) }
          .to change(Notification, :count).by(1)
      end

      it 'a queued email represents an individual ticket post' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               channel: 'email',
               state: 'queued',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'post_ids' => [SecureRandom.uuid] })
        params = notification_params.merge(channel: 'email', payload: { post_ids: [SecureRandom.uuid] })

        expect { builder.find_or_create_group(params) }
          .to change(Notification, :count).by(1)
      end

      it 'existing group has reached MAX_GROUP_SIZE' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: described_class::MAX_GROUP_SIZE,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'existing notification has high priority' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'high',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'existing notification has critical priority' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'critical',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'existing notification is outside the time window' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'normal',
               created_at: 6.minutes.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'notifiable type does not match trackable' do
        other_ticket = create(:ticket, project: project, organisation: organisation)
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: other_ticket,
               event_type: 'ticket_commented',
               state: 'queued',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'commented' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end

      it 'event types are incompatible' do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               group_key: builder.build,
               group_count: 1,
               notifiable: ticket,
               event_type: 'ticket_assigned', # incompatible with 'ticket_commented'
               state: 'queued',
               priority: 'normal',
               created_at: 1.minute.ago,
               actor: actor,
               payload: { 'action' => 'assigned' })

        expect { builder.find_or_create_group(notification_params) }
          .to change(Notification, :count).by(1)
      end
    end

    # --- Dedupe fingerprint uniqueness ---------------------------------------
    describe 'dedupe fingerprint' do
      it 'generates different fingerprints for different activities' do
        fp1 = builder.send(:generate_dedupe_fingerprint, notification_params)

        activity2 = create(:activity,
                           actor: other_actor,
                           organisation: organisation,
                           trackable: ticket,
                           action: 'ticket_commented',
                           key: 'ticket.ticket_commented')
        builder2 = described_class.new(activity2, recipient)
        fp2 = builder2.send(:generate_dedupe_fingerprint, notification_params)

        # Fingerprints differ because activity_id differs
        expect(fp1).not_to eq(fp2)
      end
    end

    # --- Folding into a found row, under the row lock -------------------------
    # What happens to a row the lookup found: when the event folds in, what a
    # fold writes, and what a refusal leaves alone. The clock stands still four
    # minutes into a bucket: the window reads the clock, the key reads the
    # activity's time, and a fold stamps the row's latest event with the clock.
    # Every row sets its own times, because the factory copies created_at into
    # both event times and so would hide a wrong span.
    describe 'folding into a found row' do
      include ActiveSupport::Testing::TimeHelpers

      let(:bucket_start) { Time.zone.local(2026, 11, 24, 14, 0, 0) }
      let(:row_time) { bucket_start + 1.minute }
      let(:now) { bucket_start + 4.minutes }
      let(:activity) do
        create(:activity, actor: actor, organisation: organisation, trackable: ticket,
                          action: 'ticket_commented', key: 'ticket.ticket_commented',
                          created_at: bucket_start + 3.minutes)
      end
      let(:kept_columns) do
        %w[group_count first_event_at last_event_at payload updated_at state read_at created_at actor_id]
      end

      before { travel_to(now) }
      after { travel_back }

      def create_row(**attributes)
        defaults = {
          recipient: recipient, organisation: organisation, notifiable: ticket,
          group_key: builder.build, group_count: 1, event_type: 'ticket_commented',
          channel: 'in_app', state: 'queued', priority: 'normal', actor: actor,
          payload: { 'action' => 'commented', 'actor_ids' => [] },
          created_at: row_time, updated_at: row_time,
          first_event_at: row_time, last_event_at: row_time
        }
        create(:notification, **defaults.merge(attributes))
      end

      # The values a fold writes, read from the database.
      def row_values(row)
        row.reload.attributes.slice(*kept_columns)
      end

      # A builder whose lookup answers from the preloaded hash, the way the
      # fanout hands in the rows it loaded for all recipients at once.
      def preloaded_builder(row)
        described_class.new(activity, recipient,
                            existing_groups: { [recipient.id, builder.build, 'in_app'] => row })
      end

      context 'when a row handed in through existing_groups was read after it was loaded' do
        it 'creates a new row and leaves the read row as it is' do
          row = create_row
          loaded_row = Notification.find(row.id)
          Notification.where(id: row.id).update_all(state: 'read', read_at: now)
          preloaded = preloaded_builder(loaded_row)

          expect(loaded_row).to have_attributes(state: 'queued', read_at: nil)
          before_call = row_values(row)
          expect(before_call).to include('state' => 'read', 'read_at' => now, 'group_count' => 1,
                                         'first_event_at' => row_time, 'last_event_at' => row_time,
                                         'updated_at' => row_time,
                                         'payload' => { 'action' => 'commented', 'actor_ids' => [] })

          answer = nil
          expect { answer = preloaded.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end
      end

      # The fanout loads its candidates before the loop. A row deleted since takes no
      # event, and the event gets a row of its own.
      context 'when a row handed in through existing_groups was deleted after it was loaded' do
        it 'creates one new row' do
          row = create_row
          loaded_row = Notification.find(row.id)
          expect(Notification.where(id: row.id)).to exist
          Notification.where(id: row.id).delete_all
          preloaded = preloaded_builder(loaded_row)
          expect(Notification.where(id: row.id)).not_to exist

          answer = nil
          expect { answer = preloaded.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)

          expect(answer.id).not_to eq(row.id)
          expect(answer.reload).to have_attributes(group_count: 1, recipient_id: recipient.id,
                                                   group_key: builder.build, state: 'queued')
        end
      end

      context 'when the found in-app row is unread' do
        # Only an email row is refused once it left the queue; an in-app row in
        # sent or delivered still takes the event and keeps its state.
        %w[queued sent delivered].each do |unread_state|
          it "folds the event in and keeps the state #{unread_state}" do
            row = create_row(state: unread_state)
            expect(row.reload).to have_attributes(state: unread_state, read_at: nil, group_count: 1,
                                                  created_at: row_time)

            expect { builder.find_or_create_group(notification_params) }
              .not_to change(Notification, :count)

            expect(row.reload).to have_attributes(state: unread_state, read_at: nil, group_count: 2,
                                                  created_at: row_time)
          end
        end
      end

      context 'with post ids on an in-app row' do
        let(:first_post_id) { SecureRandom.uuid }
        let(:second_post_id) { SecureRandom.uuid }
        let(:payload_with_post) { { 'action' => 'commented', 'actor_ids' => [], 'post_ids' => [first_post_id] } }

        it 'does not put an event with post ids into a row without them' do
          row = create_row
          before_call = row_values(row)
          expect(before_call).to include('group_count' => 1, 'first_event_at' => row_time,
                                         'last_event_at' => row_time, 'updated_at' => row_time,
                                         'payload' => { 'action' => 'commented', 'actor_ids' => [] })

          answer = nil
          expect { answer = builder.find_or_create_group(notification_params.merge(payload: { post_ids: [second_post_id] })) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end

        it 'does not put an event without post ids into a row with them' do
          row = create_row(payload: payload_with_post)
          before_call = row_values(row)
          expect(before_call).to include('group_count' => 1, 'first_event_at' => row_time,
                                         'last_event_at' => row_time, 'updated_at' => row_time,
                                         'payload' => payload_with_post)

          answer = nil
          expect { answer = builder.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end

        it 'puts an event with post ids into a row with them and keeps both ids' do
          row = create_row(payload: payload_with_post)

          expect { builder.find_or_create_group(notification_params.merge(payload: { post_ids: [second_post_id] })) }
            .not_to change(Notification, :count)

          row.reload
          expect(row.group_count).to eq(2)
          expect(row.payload['post_ids']).to contain_exactly(first_post_id, second_post_id)
        end
      end

      context 'when the event folds in' do
        around { |example| with_test_queue_adapter { example.run } }

        it 'refreshes the unread signal of the recipient' do
          row = create_row
          clear_enqueued_jobs
          expect(activity.created_at).to be > row.reload.last_event_at
          count_before = Notification.count

          expect { builder.find_or_create_group(notification_params) }
            .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: recipient.id)

          expect(Notification.count).to eq(count_before)
          expect(row.reload).to have_attributes(group_count: 2, last_event_at: now)
        end

        it 'moves updated_at to the time of the fold' do
          row = create_row
          expect(row.reload.updated_at).to eq(row_time)

          builder.find_or_create_group(notification_params)

          expect(row.reload).to have_attributes(group_count: 2, updated_at: now)
        end
      end

      context 'when the row lock refuses the fold' do
        it 'leaves a high priority row as it is and creates a new row' do
          row = create_row(priority: 'high')
          before_call = row_values(row)
          expect(before_call).to include('group_count' => 1, 'first_event_at' => row_time,
                                         'last_event_at' => row_time, 'updated_at' => row_time,
                                         'payload' => { 'action' => 'commented', 'actor_ids' => [] })

          answer = nil
          expect { answer = builder.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end
      end

      # The lookup query already filters size and age, so only a row handed in
      # through existing_groups reaches these two checks of can_add_to_group?.
      # The fanout hands in rows it loaded before its loop. The rule must be
      # asked about the row as the lock reads it again, not about that object.
      context 'when a row handed in through existing_groups changed in the database after it was loaded' do
        def changed_after_load(row, **changes)
          loaded_row = Notification.find(row.id)
          Notification.where(id: row.id).update_all(changes)
          loaded_row
        end

        def expect_new_row_and_unchanged(row, loaded_row)
          before_call = row_values(row)
          answer = nil
          expect { answer = preloaded_builder(loaded_row).find_or_create_group(params_for(loaded_row)) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end

        def params_for(loaded_row)
          notification_params.merge(channel: loaded_row.channel)
        end

        def preloaded_builder(row)
          described_class.new(activity, recipient,
                              existing_groups: { [recipient.id, builder.build, row.channel] => row })
        end

        it 'does not fold into a row raised to high priority after it was loaded' do
          row = create_row
          loaded_row = changed_after_load(row, priority: 'high')
          expect(loaded_row).to have_attributes(priority: 'normal', group_count: 1)
          expect(row_values(row)).to include('group_count' => 1, 'last_event_at' => row_time,
                                             'updated_at' => row_time)

          expect_new_row_and_unchanged(row, loaded_row)
          expect(Notification.find(row.id).priority).to eq('high')
        end

        it 'does not fold into an email row sent after it was loaded' do
          row = create_row(channel: 'email')
          loaded_row = changed_after_load(row, state: 'sent', sent_at: now)
          expect(loaded_row).to have_attributes(channel: 'email', state: 'queued', group_count: 1)
          expect(row_values(row)).to include('state' => 'sent', 'group_count' => 1, 'last_event_at' => row_time)

          expect_new_row_and_unchanged(row, loaded_row)
        end

        it 'does not fold into a row that reached MAX_GROUP_SIZE after it was loaded' do
          row = create_row
          loaded_row = changed_after_load(row, group_count: described_class::MAX_GROUP_SIZE)
          expect(loaded_row.group_count).to eq(1)
          expect(row_values(row)).to include('group_count' => described_class::MAX_GROUP_SIZE,
                                             'last_event_at' => row_time)

          expect_new_row_and_unchanged(row, loaded_row)
        end
      end

      # The fanout names the actor as a record (`actor:`), never as `actor_id:`.
      context 'when the actor of the event comes as a record' do
        it 'writes that actor into the row and into its actor ids' do
          row = create_row
          params = notification_params.except(:actor_id).merge(actor: other_actor)
          expect(row.reload).to have_attributes(actor_id: actor.id)

          expect { builder.find_or_create_group(params) }.not_to change(Notification, :count)

          row.reload
          expect(row.actor_id).to eq(other_actor.id)
          expect(row.payload['actor_ids']).to contain_exactly(actor.id, other_actor.id)
        end
      end

      context 'when a row handed in through existing_groups is full or old' do
        it 'does not fold into a row that holds MAX_GROUP_SIZE events' do
          row = create_row(group_count: described_class::MAX_GROUP_SIZE)
          before_call = row_values(row)
          expect(before_call).to include('group_count' => described_class::MAX_GROUP_SIZE,
                                         'first_event_at' => row_time, 'last_event_at' => row_time,
                                         'updated_at' => row_time)

          answer = nil
          expect { answer = preloaded_builder(row).find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end

        it 'does not fold into a row created before the time window' do
          old_time = now - 6.minutes
          row = create_row(created_at: old_time, updated_at: old_time,
                           first_event_at: old_time, last_event_at: old_time)
          before_call = row_values(row)
          expect(before_call).to include('group_count' => 1, 'created_at' => old_time,
                                         'first_event_at' => old_time, 'last_event_at' => old_time,
                                         'updated_at' => old_time)

          answer = nil
          expect { answer = preloaded_builder(row).find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end
      end

      context 'when the found row is about another kind of record' do
        # A project that shares the ticket's id: only the type tells the two
        # apart, so the id check after it cannot refuse the row instead.
        it 'does not fold into a row of another notifiable type with the same id' do
          same_id_project = create(:project, id: ticket.id, organisation: organisation)
          row = create_row(notifiable: same_id_project)
          before_call = row_values(row)
          expect(row).to have_attributes(notifiable_type: 'Project', notifiable_id: ticket.id)
          expect(before_call).to include('group_count' => 1, 'first_event_at' => row_time,
                                         'last_event_at' => row_time, 'updated_at' => row_time)

          answer = nil
          expect { answer = builder.find_or_create_group(notification_params) }
            .to change(Notification, :count).by(1)
          expect(answer.id).not_to eq(row.id)
          expect(row_values(row)).to eq(before_call)
        end
      end

      context 'when the found row is a queued email' do
        it 'folds an event without post ids into it' do
          row = create_row(channel: 'email')
          expect(row.reload).to have_attributes(channel: 'email', state: 'queued', group_count: 1)

          expect { builder.find_or_create_group(notification_params.merge(channel: 'email')) }
            .not_to change(Notification, :count)

          expect(row.reload).to have_attributes(group_count: 2, first_event_at: row_time, last_event_at: now)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private method unit tests
  # ---------------------------------------------------------------------------
  describe 'private methods' do
    describe '#compatible_event_types?' do
      it 'returns true for identical event types' do
        result = builder.send(:compatible_event_types?, 'ticket_commented', 'ticket_commented')
        expect(result).to be true
      end

      it 'returns true for types in the same groupable set' do
        result = builder.send(:compatible_event_types?, 'ticket_commented', 'ticket_replied')
        expect(result).to be true
      end

      it 'returns true for cross-set compatible status types' do
        result = builder.send(:compatible_event_types?, 'ticket_status_changed', 'ticket_updated')
        expect(result).to be true
      end

      it 'returns false for types in different sets' do
        result = builder.send(:compatible_event_types?, 'ticket_commented', 'ticket_status_changed')
        expect(result).to be false
      end

      it 'returns false for types not in any set' do
        result = builder.send(:compatible_event_types?, 'custom_event', 'other_event')
        expect(result).to be false
      end

      it 'handles nil-ish values via to_s' do
        result = builder.send(:compatible_event_types?, nil, nil)
        expect(result).to be true # both convert to empty string, which are equal
      end
    end

    describe '#generate_dedupe_fingerprint' do
      let(:params) do
        {
          recipient_id: recipient.id,
          notifiable_type: 'Ticket',
          notifiable_id: ticket.id,
          event_type: 'ticket_commented',
          channel: 'in_app'
        }
      end

      it 'generates a 64-character SHA256 hex string' do
        fingerprint = builder.send(:generate_dedupe_fingerprint, params)
        expect(fingerprint).to match(/\A[a-f0-9]{64}\z/)
      end

      it 'is deterministic for the same inputs' do
        fp1 = builder.send(:generate_dedupe_fingerprint, params)
        fp2 = builder.send(:generate_dedupe_fingerprint, params)
        expect(fp1).to eq(fp2)
      end

      it 'changes when activity_id differs' do
        fp1 = builder.send(:generate_dedupe_fingerprint, params)

        other_activity = instance_double(Activity,
                                         trackable: ticket,
                                         action: 'ticket_commented',
                                         created_at: Time.current,
                                         id: SecureRandom.uuid)
        other_builder = described_class.new(other_activity, recipient)
        fp2 = other_builder.send(:generate_dedupe_fingerprint, params)

        expect(fp1).not_to eq(fp2)
      end

      it 'changes when recipient_id differs' do
        fp1 = builder.send(:generate_dedupe_fingerprint, params)
        fp2 = builder.send(:generate_dedupe_fingerprint, params.merge(recipient_id: SecureRandom.uuid))
        expect(fp1).not_to eq(fp2)
      end

      it 'handles nil components' do
        sparse_params = { recipient_id: nil, notifiable_type: nil }
        expect { builder.send(:generate_dedupe_fingerprint, sparse_params) }.not_to raise_error
      end
    end

    describe '#determine_project' do
      it 'returns the project when trackable is a Project' do
        act = instance_double(Activity,
                              trackable: project,
                              action: 'created',
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)

        expect(b.send(:determine_project)).to eq(project)
      end

      it 'returns the ticket project when trackable is a Ticket' do
        expect(builder.send(:determine_project)).to eq(project)
      end

      it 'returns nil when trackable is nil' do
        act = instance_double(Activity,
                              trackable: nil,
                              action: 'created',
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)

        expect(b.send(:determine_project)).to be_nil
      end

      it 'follows ticket association for nested trackables' do
        trackable = double('Comment', ticket: ticket)
        allow(trackable).to receive(:is_a?).and_return(false)
        allow(trackable).to receive(:respond_to?).with(:project).and_return(false)
        allow(trackable).to receive(:respond_to?).with(:ticket).and_return(true)
        allow(trackable).to receive(:class).and_return(Class.new { def self.name = 'Comment' })

        act = instance_double(Activity,
                              trackable: trackable,
                              action: 'created',
                              created_at: Time.current,
                              id: SecureRandom.uuid)
        b = described_class.new(act, recipient)

        expect(b.send(:determine_project)).to eq(project)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------
  describe 'constants' do
    it 'defines GROUP_TIME_WINDOW as 5 minutes' do
      expect(described_class::GROUP_TIME_WINDOW).to eq(5.minutes)
    end

    it 'defines MAX_GROUP_SIZE as 10' do
      expect(described_class::MAX_GROUP_SIZE).to eq(10)
    end

    it 'freezes ACTION_NORMALIZATIONS' do
      expect(described_class::ACTION_NORMALIZATIONS).to be_frozen
    end

    it 'freezes GROUPABLE_EVENT_SETS and its contents' do
      expect(described_class::GROUPABLE_EVENT_SETS).to be_frozen
      described_class::GROUPABLE_EVENT_SETS.each do |set|
        expect(set).to be_frozen
      end
    end
  end
end
