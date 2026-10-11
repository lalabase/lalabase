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

      it 'sets first_event_at and last_event_at from activity' do
        notification = builder.find_or_create_group(notification_params)
        expect(notification.first_event_at).to eq(activity.created_at)
        expect(notification.last_event_at).to eq(activity.created_at)
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

      it 'updates last_event_at to the activity timestamp' do
        builder.find_or_create_group(notification_params)
        expect(existing_notification.reload.last_event_at).to eq(activity.created_at)
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

    describe '#merge_payload' do
      let(:notification) { Notification.new(payload: { 'tags' => %w[a b], 'status' => 'open' }) }

      it 'merges two arrays by concatenation and deduplication' do
        builder.send(:merge_payload, notification, { 'tags' => %w[b c] })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'appends a scalar to an existing array' do
        builder.send(:merge_payload, notification, { 'tags' => 'c' })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'prepends existing scalar to a new array' do
        builder.send(:merge_payload, notification, { 'status' => %w[closed archived] })
        expect(notification.payload['status']).to eq(%w[open closed archived])
      end

      it 'overwrites scalar with latest scalar' do
        builder.send(:merge_payload, notification, { 'status' => 'closed' })
        expect(notification.payload['status']).to eq('closed')
      end

      it 'adds new keys that did not exist before' do
        builder.send(:merge_payload, notification, { 'new_key' => 'new_value' })
        expect(notification.payload['new_key']).to eq('new_value')
      end

      it 'handles nil new_payload gracefully' do
        expect { builder.send(:merge_payload, notification, nil) }.not_to raise_error
        expect(notification.payload).to eq({ 'tags' => %w[a b], 'status' => 'open' })
      end

      it 'handles nil existing payload' do
        notification.payload = nil
        builder.send(:merge_payload, notification, { 'key' => 'val' })
        expect(notification.payload['key']).to eq('val')
      end

      it 'deduplicates when merging arrays' do
        builder.send(:merge_payload, notification, { 'tags' => %w[a a b c c] })
        expect(notification.payload['tags']).to eq(%w[a b c])
      end

      it 'merges symbol-keyed arrays into persisted string-keyed payloads' do
        notification.payload = { 'post_ids' => ['post-1'] }

        builder.send(:merge_payload, notification, { post_ids: ['post-2'] })

        expect(notification.payload['post_ids']).to contain_exactly('post-1', 'post-2')
      end

      it 'compacts nil values when prepending scalar to array' do
        notification.payload['nullable'] = nil
        builder.send(:merge_payload, notification, { 'nullable' => %w[x y] })
        expect(notification.payload['nullable']).to eq(%w[x y])
      end
    end

    describe '#merge_actors' do
      let(:notification) do
        Notification.new(
          actor_id: actor.id,
          payload: { 'actor_ids' => [] }
        )
      end

      it 'adds the existing actor_id and the new actor_id' do
        builder.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to contain_exactly(actor.id, other_actor.id)
      end

      it 'updates actor_id to the new actor' do
        builder.send(:merge_actors, notification, other_actor.id)
        expect(notification.actor_id).to eq(other_actor.id)
      end

      it 'deduplicates actor ids' do
        builder.send(:merge_actors, notification, actor.id)
        expect(notification.payload['actor_ids']).to eq([actor.id])
      end

      it 'handles nil new_actor_id' do
        builder.send(:merge_actors, notification, nil)
        expect(notification.payload['actor_ids']).to eq([actor.id])
        expect(notification.actor_id).to eq(actor.id)
      end

      it 'handles nil existing actor_id' do
        notification.actor_id = nil
        builder.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to eq([other_actor.id])
      end

      it 'handles missing actor_ids key in payload' do
        notification.payload = {}
        builder.send(:merge_actors, notification, other_actor.id)
        expect(notification.payload['actor_ids']).to contain_exactly(actor.id, other_actor.id)
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
