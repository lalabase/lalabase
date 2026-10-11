# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::FanoutService, 'simplified ticket notifications' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { create(:user) }
  let(:watcher) { create(:user) }
  let(:actor) { create(:user) }
  let(:ticket) { create(:ticket, project: project, creator: creator) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = actor

    create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: watcher, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)

    # Watcher manually subscribes to ticket
    NotificationSubscription.create!(user: watcher, subscribable: ticket, mode: 'follow')
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  def create_outbox_event(activity)
    create(:outbox_event,
           organisation: organisation,
           activity: activity,
           event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
           payload: activity.parameters || {})
  end

  def run_fanout(activity)
    outbox_event = create_outbox_event(activity)
    # Pause N+1 detection - fanout internals trigger Prosopite
    Prosopite.pause
    result = described_class.new(outbox_event).call
    Prosopite.resume
    result
  end

  def notifications_for(user, channel: 'in_app')
    Notification.where(recipient: user, notifiable: ticket, channel: channel)
  end

  # =========================================================================
  # Subscriber gets notifications
  # =========================================================================

  describe 'subscriber receives notifications' do
    it 'receives notification for ticket comment' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher)).to exist
    end

    it 'retains every post id when comments are grouped' do
      first_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      second_post = create(:post, organisation: organisation, ticket: ticket, user: actor)

      [first_post, second_post].each do |post_record|
        activity = create(:activity, :post_added,
                          organisation: organisation, trackable: ticket, actor: actor,
                          secondary: post_record)
        run_fanout(activity)
      end

      in_app = notifications_for(watcher).sole
      emails = notifications_for(watcher, channel: 'email')

      expect(in_app.payload['post_ids']).to contain_exactly(first_post.id, second_post.id)
      expect(emails.count).to eq(2)
      expect(emails.flat_map { |notification| notification.payload['post_ids'] })
        .to contain_exactly(first_post.id, second_post.id)
    end

    it 'keeps a sent email immutable when a later comment is grouped' do
      first_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      first_activity = create(:activity, :post_added,
                              organisation: organisation, trackable: ticket, actor: actor,
                              secondary: first_post)
      run_fanout(first_activity)
      sent_email = notifications_for(watcher, channel: 'email').sole
      sent_email.update!(state: :sent, sent_at: Time.current)

      second_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      second_activity = create(:activity, :post_added,
                               organisation: organisation, trackable: ticket, actor: actor,
                               secondary: second_post)
      run_fanout(second_activity)

      expect(sent_email.reload.payload['post_ids']).to contain_exactly(first_post.id)
      expect(notifications_for(watcher, channel: 'email').count).to eq(2)
      expect(notifications_for(watcher, channel: 'email').where.not(id: sent_email.id).sole.payload['post_ids'])
        .to contain_exactly(second_post.id)
    end

    it 'pairs the latest comment with its author when different authors are grouped' do
      second_author = create(:user)
      at = Time.current
      [actor, second_author].each_with_index do |author, index|
        post_record = create(:post, organisation: organisation, ticket: ticket, user: author)
        activity = create(:activity, :post_added, organisation: organisation,
                                                  trackable: ticket, actor: author, secondary: post_record,
                                                  created_at: at, parameters: { post_excerpt: "Comment #{index + 1}" })
        expect(run_fanout(activity)[:success]).to be true
      end

      notification = notifications_for(watcher).sole
      expect(notification.payload.dig('parameters', 'post_excerpt')).to eq('Comment 2')
      expect(notification.actor).to eq(second_author)
      expect(notification.payload['actor_ids']).to contain_exactly(actor.id, second_author.id)
    end

    it 'keeps a legacy unread comment separate from a newly acknowledged post' do
      old_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      new_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      activity = create(:activity, :post_added, organisation: organisation,
                                                trackable: ticket, actor: actor, secondary: new_post)
      legacy = create(:notification, :ticket_commented,
                      organisation: organisation, recipient: watcher, actor: actor,
                      notifiable: ticket, project: project, created_at: Time.current,
                      group_key: Notifications::GroupKeyBuilder.new(activity, watcher).build,
                      payload: { 'activity_id' => SecureRandom.uuid })
      create(:post_read, organisation: organisation, post: new_post, user: watcher)

      expect(run_fanout(activity)[:success]).to be true

      expect(legacy.reload).to be_unread
      expect(legacy.group_count).to eq(1)
      expect(PostRead.where(post: old_post, user: watcher)).not_to exist
      expect(notifications_for(watcher).where.not(id: legacy.id).sole).to be_state_read
    end

    it 'reconciles existing receipts even when a grouped post has been deleted' do
      deleted_post = create(:post, organisation: organisation, ticket: ticket, user: actor)
      post_record = create(:post, organisation: organisation, ticket: ticket, user: actor)
      activity = create(:activity, :post_added, organisation: organisation,
                                                trackable: ticket, actor: actor, secondary: post_record)
      notification = create(:notification, :ticket_commented,
                            organisation: organisation, recipient: watcher, actor: actor,
                            notifiable: ticket, project: project, created_at: Time.current,
                            group_key: Notifications::GroupKeyBuilder.new(activity, watcher).build,
                            payload: { 'post_ids' => [deleted_post.id] })
      deleted_post.destroy!
      create(:post_read, organisation: organisation, post: post_record, user: watcher)

      expect(run_fanout(activity)[:success]).to be true

      expect(notification.reload).to be_state_read
    end

    it 'does not recreate an unread in-app notification after the post was acknowledged' do
      post_record = create(:post, organisation: organisation, ticket: ticket, user: actor)
      create(:post_read, organisation: organisation, post: post_record, user: watcher)
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor,
                        secondary: post_record)

      run_fanout(activity)

      expect(notifications_for(watcher).sole).to be_state_read
      expect(notifications_for(watcher, channel: 'email').sole).to be_unread
    end

    it 'receives notification for ticket status change' do
      activity = create(:activity, :status_changed,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher)).to exist
    end

    it 'creates both in_app and email notifications' do
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher, channel: 'in_app')).to exist
      expect(notifications_for(watcher, channel: 'email')).to exist
    end
  end

  # =========================================================================
  # Self-action suppression
  # =========================================================================

  describe 'self-action suppression' do
    it 'does NOT notify the actor' do
      # Actor is also a subscriber
      NotificationSubscription.find_or_create_by(user: actor, subscribable: ticket, mode: 'follow')

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(actor)).not_to exist
    end
  end

  # =========================================================================
  # Event-type user settings
  # =========================================================================

  describe 'user event-type settings' do
    it 'does NOT notify when comment notifications disabled' do
      watcher.notification_settings.update('on_comment' => false)

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher)).not_to exist
    end

    it 'does NOT notify when status_change notifications disabled' do
      watcher.notification_settings.update('on_status_change' => false)

      activity = create(:activity, :status_changed,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher)).not_to exist
    end

    it 'still notifies for assignments even when other settings disabled' do
      watcher.notification_settings.update(
        'on_comment' => false,
        'on_status_change' => false,
        'on_priority_change' => false
      )

      activity = create(:activity, :assigned,
                        organisation: organisation, trackable: ticket, actor: actor,
                        parameters: { 'assignee_id' => watcher.id, 'assignee_name' => watcher.full_name })
      run_fanout(activity)

      expect(notifications_for(watcher)).to exist
    end
  end

  # =========================================================================
  # Non-subscriber exclusion
  # =========================================================================

  describe 'non-subscriber exclusion' do
    it 'does NOT notify a user without subscription' do
      outsider = create(:user)
      create(:membership, user: outsider, organisation: organisation, role: admin_role, active: true)

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(Notification.where(recipient: outsider, notifiable: ticket)).not_to exist
    end
  end

  # =========================================================================
  # Muted subscriber
  # =========================================================================

  describe 'muted subscriber' do
    it 'does NOT notify when subscription is muted' do
      sub = NotificationSubscription.find_by(user: watcher, subscribable: ticket)
      sub.update!(mode: 'mute')

      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: actor)
      run_fanout(activity)

      expect(notifications_for(watcher)).not_to exist
    end
  end

  # =========================================================================
  # Assignment target
  # =========================================================================

  describe 'assignment target' do
    it 'notifies the assigned user even without prior subscription' do
      new_user = create(:user)
      create(:membership, user: new_user, organisation: organisation, role: admin_role, active: true)

      activity = create(:activity, :assigned,
                        organisation: organisation, trackable: ticket, actor: actor,
                        secondary: new_user,
                        parameters: { 'assignee_id' => new_user.id, 'assignee_name' => new_user.full_name })
      run_fanout(activity)

      expect(Notification.where(recipient: new_user, notifiable: ticket)).to exist
    end
  end

  # =========================================================================
  # Unassignment target
  # =========================================================================

  describe 'unassignment target' do
    it 'notifies the unassigned user' do
      unassigned_user = create(:user)
      create(:membership, user: unassigned_user, organisation: organisation, role: admin_role, active: true)
      NotificationSubscription.create!(user: unassigned_user, subscribable: ticket, mode: 'follow')

      activity = create(:activity,
                        organisation: organisation, trackable: ticket, actor: actor,
                        action: 'unassigned', key: 'ticket.unassigned',
                        parameters: { 'unassignee_id' => unassigned_user.id, 'unassignee_name' => unassigned_user.full_name })
      run_fanout(activity)

      expect(Notification.where(recipient: unassigned_user, notifiable: ticket)).to exist
    end
  end
end
