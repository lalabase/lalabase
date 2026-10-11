# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Posts::MarkRead do
  let(:organisation) { create(:organisation) }
  let(:reader) { create(:user) }
  let(:author) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: author) }
  let(:post_record) { create(:post, organisation: organisation, ticket: ticket, user: author) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'records the exact post read and consumes only its comment notification' do
    matching = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project,
      payload: { 'post_ids' => [post_record.id.to_s] }
    )
    unrelated = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project,
      payload: { 'post_ids' => [SecureRandom.uuid] }
    )
    matching_email = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project, channel: 'email',
      payload: { 'post_ids' => [post_record.id.to_s] }
    )

    read, notifications = described_class.call(post: post_record, user: reader)

    expect(read).to have_attributes(post: post_record, user: reader)
    expect(read.read_at).to be_present
    expect(notifications).to contain_exactly(matching)
    expect(matching.reload).to be_state_read
    expect(matching_email.reload).to be_unread
    expect(unrelated.reload).to be_unread
  end

  it 'keeps the read receipt when called again' do
    first_read, = described_class.call(post: post_record, user: reader)

    expect do
      described_class.call(post: post_record, user: reader)
    end.not_to(change(PostRead, :count))
    expect(PostRead.find(first_read.id).read_at).to eq(first_read.read_at)
  end

  it 'consumes a group after every surviving post has been read' do
    deleted_post = create(:post, organisation: organisation, ticket: ticket, user: author)
    notification = create(:notification, :ticket_commented,
                          organisation: organisation, recipient: reader, actor: author,
                          notifiable: ticket, project: project, group_count: 2,
                          payload: { 'post_ids' => [deleted_post.id, post_record.id] })
    described_class.call(post: deleted_post, user: reader)
    deleted_post.destroy!

    described_class.call(post: post_record, user: reader)

    expect(notification.reload).to be_state_read
  end

  it 'keeps a grouped notification unread until every represented post is read' do
    other_post = create(:post, organisation: organisation, ticket: ticket, user: author)
    notification = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project,
      payload: { 'post_ids' => [post_record.id.to_s, other_post.id.to_s] }
    )

    _read, notifications = described_class.call(post: post_record, user: reader)

    expect(notifications).to be_empty
    expect(notification.reload).to be_unread

    create(:post_read, organisation: organisation, post: other_post, user: reader)
    _read, notifications = described_class.call(post: post_record, user: reader)

    expect(notifications).to contain_exactly(notification)
    expect(notification.reload).to be_state_read
  end

  it 'recognizes a legacy grouped notification by the post activity interval' do
    activity = create(
      :activity, :post_added,
      organisation: organisation, actor: author, trackable: ticket,
      secondary: post_record, created_at: post_record.created_at
    )
    notification = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project,
      payload: { 'activity_id' => SecureRandom.uuid },
      first_event_at: activity.created_at - 1.second,
      last_event_at: activity.created_at + 1.second
    )

    _read, notifications = described_class.call(post: post_record, user: reader)

    expect(notifications).to contain_exactly(notification)
    expect(notification.reload).to be_state_read
  end

  it 'keeps an ambiguous legacy group unread when it has no represented post ids' do
    activity = create(
      :activity, :post_added,
      organisation: organisation, actor: author, trackable: ticket,
      secondary: post_record, created_at: post_record.created_at
    )
    notification = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: reader, actor: author,
      notifiable: ticket, project: project, group_count: 2,
      payload: { 'activity_id' => SecureRandom.uuid },
      first_event_at: activity.created_at - 1.second,
      last_event_at: activity.created_at + 1.second
    )

    _read, notifications = described_class.call(post: post_record, user: reader)

    expect(notifications).to be_empty
    expect(notification.reload).to be_unread
  end
end
