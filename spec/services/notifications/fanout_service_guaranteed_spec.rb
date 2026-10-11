# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::FanoutService, 'guaranteed recipients' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { create(:user) }
  let(:assignee) { create(:user) }
  let(:actor) { create(:user) }
  let(:ticket) { create(:ticket, project: project, creator: creator) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = actor

    create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)

    # Add the assignee to the ticket
    ticket.assignees << assignee
  end

  def create_outbox_event(activity)
    create(:outbox_event,
           organisation: organisation,
           activity: activity,
           event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
           payload: activity.parameters || {})
  end

  def run_fanout(activity)
    outbox_event = create_outbox_event(activity)
    described_class.new(outbox_event).call
  end

  def notifications_for(user)
    Notification.where(recipient: user, notifiable: ticket, channel: 'in_app')
  end

  describe 'ticket creator receives notifications' do
    it 'receives notification for ticket comment (post_added)' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(creator)).to exist
    end

    it 'receives notification for ticket status change' do
      activity = create(:activity, :status_changed,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(creator)).to exist
    end

    it 'receives notification for ticket assignment' do
      new_user = create(:user)
      create(:membership, user: new_user, organisation: organisation, active: true)

      activity = create(:activity, :assigned,
                        organisation: organisation, trackable: ticket, actor: actor,
                        secondary: new_user)
      run_fanout(activity)

      expect(notifications_for(creator)).to exist
    end

    it 'does NOT receive notification when creator is the actor' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: creator)
      run_fanout(activity)

      expect(notifications_for(creator)).not_to exist
    end

    it 'does NOT receive notification when creator has muted the ticket' do
      # auto_subscribe_creator has already created a subscription, switch it to mute
      sub = NotificationSubscription.find_by(user: creator, subscribable: ticket)
      if sub
        sub.update!(mode: 'mute')
      else
        NotificationSubscription.new(
          user: creator, subscribable: ticket, organisation: organisation, mode: 'mute'
        ).save!(validate: false)
      end

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(creator)).not_to exist
    end
  end

  describe 'ticket assignee receives notifications' do
    it 'receives notification for ticket comment' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(assignee)).to exist
    end

    it 'receives notification for ticket status change' do
      activity = create(:activity, :status_changed,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(assignee)).to exist
    end

    it 'does NOT receive notification when assignee is the actor' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: assignee)
      run_fanout(activity)

      expect(notifications_for(assignee)).not_to exist
    end

    it 'does NOT receive notification when assignee has muted the ticket' do
      sub = NotificationSubscription.find_by(user: assignee, subscribable: ticket)
      if sub
        sub.update!(mode: 'mute')
      else
        NotificationSubscription.new(
          user: assignee, subscribable: ticket, organisation: organisation, mode: 'mute'
        ).save!(validate: false)
      end

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(assignee)).not_to exist
    end
  end

  describe 'guaranteed_recipient_ids (non-ticket path only)' do
    # NOTE: For tickets, guaranteed_recipient_ids is not used.
    # Ticket recipients are handled by the subscription-based path.
    # guaranteed_recipient_ids only applies to Document/Note items.

    it 'returns empty set for ticket items (tickets use subscription path)' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      outbox_event = create_outbox_event(activity)
      service = described_class.new(outbox_event)

      ids = service.send(:guaranteed_recipient_ids)

      expect(ids).to be_empty
    end

    it 'ticket creator still receives notifications via subscription path' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(creator)).to exist
    end

    it 'ticket assignee still receives notifications via subscription path' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(assignee)).to exist
    end
  end
end
