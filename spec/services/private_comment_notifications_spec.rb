# frozen_string_literal: true

require 'rails_helper'

# What: a private comment leaves no text in the activity feed and reaches only the
#   people Post.readable_by lets read it, as a notification and as a mail.
# Why: until 27.09.2026 track_post_added stored a 100-character excerpt of every
#   comment, and the fanout notified every follower of the ticket. The excerpt showed
#   up in the project feed, in GET /api/v1/tickets/:id/activities and on notification
#   cards; the mail to each follower even carried the comment itself. A comment that
#   turns private later had already left its excerpt behind.
RSpec.describe 'Private comments in activities and notifications', :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:colleague) { create(:user) }
  let(:addressee) { create(:user) }

  let(:secret) { 'Salary figure for the review' }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [author, colleague, addressee].each do |user|
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
        NotificationSubscription.create!(user: user, subscribable: ticket, mode: :follow)
      end
    end
  end

  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  def save_post(id: nil, **params)
    Prosopite.pause do
      Actors::SavePost.call(ticket: ticket, params: params, current_user: author, id: id).resource
    end
  end

  def post_added_activity(post)
    Activity.find_by!(action: 'post_added', secondary: post)
  end

  def run_fanout(activity)
    outbox = create(:outbox_event, organisation: organisation, activity: activity,
                                   event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                                   payload: activity.parameters || {})
    Prosopite.pause { Notifications::FanoutService.new(outbox).call }
  end

  def notified?(user)
    Notification.exists?(recipient: user, notifiable: ticket)
  end

  describe 'the post_added activity' do
    it 'keeps the excerpt of a public comment' do
      post = save_post(content: secret)

      expect(post_added_activity(post).parameters['post_excerpt']).to eq(secret)
    end

    it 'stores no excerpt of a private comment' do
      post = save_post(content: secret, is_private: true)

      expect(post_added_activity(post).parameters).not_to have_key('post_excerpt')
    end
  end

  describe 'the fanout' do
    it 'notifies the followers of a public comment' do
      run_fanout(post_added_activity(save_post(content: secret)))

      expect([colleague, addressee].map { |user| notified?(user) }).to eq([true, true])
    end

    it 'notifies nobody else of a note to self' do
      run_fanout(post_added_activity(save_post(content: secret, is_private: true)))

      expect([colleague, addressee].map { |user| notified?(user) }).to eq([false, false])
    end

    it 'notifies the addressee of an addressed comment, and only them' do
      run_fanout(post_added_activity(save_post(content: secret, is_private: true, visible_to_user_id: addressee.id)))

      expect(notified?(addressee)).to be(true)
      expect(notified?(colleague)).to be(false)
    end

    it 'does not notify a mentioned colleague who may not read the comment' do
      post = save_post(content: secret, is_private: true)
      activity = post_added_activity(post)
      activity.update_columns(key: 'ticket.mentioned',
                              parameters: activity.parameters.merge('mentioned_user_ids' => [colleague.id]))

      run_fanout(activity)

      expect(notified?(colleague)).to be(false)
    end
  end

  describe 'a public comment that turns private' do
    it 'loses its excerpt in the activity and in the notifications already sent' do
      post = save_post(content: secret)
      run_fanout(post_added_activity(post))
      expect(Notification.find_by!(recipient: colleague).payload.dig('parameters', 'post_excerpt')).to eq(secret)

      save_post(is_private: true, id: post.id)

      expect(post_added_activity(post).reload.parameters).not_to have_key('post_excerpt')
      expect(Notification.where(recipient: [colleague, addressee]).map { |n| n.payload.to_json })
        .to all(satisfy { |json| !json.include?(secret) })
    end
  end
end
