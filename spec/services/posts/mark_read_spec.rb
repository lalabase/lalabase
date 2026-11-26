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

  # A comment row is also found by its span of events (first_event_at up to
  # last_event_at), the seam for rows from before payload.post_ids. A row that
  # carries post ids is decided by those ids alone, however far its span
  # reaches: it may cover the time of another comment of the same ticket.
  context 'when the span of a row with post ids covers the activity of another comment' do
    let(:activity_time) { Time.zone.local(2026, 11, 24, 14, 0, 0) }
    let(:span_start) { activity_time - 1.hour }
    let(:span_end) { activity_time + 2.hours }
    let(:other_post) { create(:post, organisation: organisation, ticket: ticket, user: author) }
    let!(:activity) do
      create(:activity, :post_added,
             organisation: organisation, actor: author, trackable: ticket,
             secondary: post_record, created_at: activity_time)
    end

    def comment_row(payload:)
      create(:notification, :ticket_commented,
             organisation: organisation, recipient: reader, actor: author,
             notifiable: ticket, project: project, payload: payload,
             created_at: span_end, first_event_at: span_start, last_event_at: span_end)
    end

    it 'leaves the row unread when the other comment is read, and reads it with its own post' do
      # The same span without post ids: reading the comment reads this row, so
      # the span does find a row here.
      row_without_ids = comment_row(payload: { 'activity_id' => SecureRandom.uuid })
      expect(row_without_ids.reload).to be_unread
      expect(activity.created_at).to be_between(row_without_ids.first_event_at, row_without_ids.last_event_at).exclusive

      _read, notifications = described_class.call(post: post_record, user: reader)

      expect(notifications).to contain_exactly(row_without_ids)
      expect(row_without_ids.reload).to be_state_read

      row_of_other_post = comment_row(payload: { 'post_ids' => [other_post.id.to_s] })
      expect(row_of_other_post.reload).to be_unread
      expect(row_of_other_post).to have_attributes(group_count: 1, first_event_at: span_start,
                                                   last_event_at: span_end, created_at: span_end)

      _read, notifications = described_class.call(post: post_record, user: reader)

      expect(notifications).to be_empty
      expect(row_of_other_post.reload).to be_unread

      _read, notifications = described_class.call(post: other_post, user: reader)

      expect(notifications).to contain_exactly(row_of_other_post)
      expect(row_of_other_post.reload).to be_state_read
    end

    it 'keeps a group with post ids unread until each of its posts is read' do
      third_post = create(:post, organisation: organisation, ticket: ticket, user: author)
      group = comment_row(payload: { 'post_ids' => [other_post.id.to_s, third_post.id.to_s] })
      group.update!(group_count: 2)
      expect(group.reload).to be_unread
      expect(activity.created_at).to be_between(group.first_event_at, group.last_event_at).exclusive

      described_class.call(post: post_record, user: reader)
      described_class.call(post: other_post, user: reader)

      expect(group.reload).to be_unread

      _read, notifications = described_class.call(post: third_post, user: reader)

      expect(notifications).to contain_exactly(group)
      expect(group.reload).to be_state_read
    end
  end
end
