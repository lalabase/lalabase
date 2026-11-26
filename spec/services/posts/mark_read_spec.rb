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

  # A comment row without post ids is also found by its span of events
  # (first_event_at up to last_event_at), the seam for rows from before
  # payload.post_ids. A row that carries post ids is decided by those ids alone
  # and never found by its span, however far it reaches: it may cover the time
  # of another comment of the same ticket. Before, the span found such a row and
  # its lock was taken; the post ids refused it only then. So these examples
  # count the locks: a row that is not found is not locked.
  context 'when the span of a row with post ids covers the activity of another comment' do
    def notification_locks(statements)
      statements.grep(/FROM "notifications".*FOR UPDATE/)
    end

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

      notifications = nil
      statements = capture_sql { _read, notifications = described_class.call(post: post_record, user: reader) }

      expect(notifications).to be_empty
      expect(notification_locks(statements)).to be_empty
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

      statements = capture_sql { described_class.call(post: post_record, user: reader) }
      expect(notification_locks(statements)).to be_empty
      described_class.call(post: other_post, user: reader)

      expect(group.reload).to be_unread

      _read, notifications = described_class.call(post: third_post, user: reader)

      expect(notifications).to contain_exactly(group)
      expect(group.reload).to be_state_read
    end
  end

  # The real chain: two comments of one ticket, more than the group window
  # apart, each row written by the fanout a while after its activity (an outbox
  # event that was delayed). A row stands at the moment its event reached it,
  # so the span of the first comment's row reaches past the activity of the
  # second comment. Each row is still read with its own comment only.
  context 'when the fanout wrote the rows of two comments late' do
    include ActiveSupport::Testing::TimeHelpers

    let(:first_comment_at) { Time.zone.local(2026, 11, 24, 14, 0, 0) }
    let(:second_comment_at) { first_comment_at + 20.minutes }
    let(:first_written_at) { first_comment_at + 30.minutes }
    let(:second_written_at) { first_comment_at + 31.minutes }
    let(:second_post) { create(:post, organisation: organisation, ticket: ticket, user: author) }
    let(:admin_role) { create(:admin_role, organisation: organisation) }

    before do
      [reader, author].each do |member|
        create(:membership, user: member, organisation: organisation, role: admin_role, active: true)
      end
      NotificationSubscription.create!(user: reader, subscribable: ticket, mode: 'follow')
    end

    after { travel_back }

    # The reader's in-app row for the comment, written by the fanout at `written_at`.
    def row_written_by_fanout(comment, commented_at:, written_at:)
      activity = create(:activity, :post_added, organisation: organisation, actor: author,
                                                trackable: ticket, secondary: comment, created_at: commented_at)
      outbox_event = create(:outbox_event, organisation: organisation, activity: activity,
                                           event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                                           payload: activity.parameters || {})
      travel_to(written_at)
      Prosopite.pause # the fanout's own lookups
      result = Notifications::FanoutService.new(outbox_event).call
      Prosopite.resume
      expect(result[:success]).to be(true)

      reader.notifications.channel_in_app.where(notifiable: ticket)
            .where('notifications.payload @> ?', { post_ids: [comment.id.to_s] }.to_json).sole
    end

    it 'reads each row with its own comment, though the first row\'s span covers the second comment' do
      first_row = row_written_by_fanout(post_record, commented_at: first_comment_at, written_at: first_written_at)
      second_row = row_written_by_fanout(second_post, commented_at: second_comment_at, written_at: second_written_at)
      expect(second_comment_at - first_comment_at).to be > Notifications::GroupKeyBuilder::GROUP_TIME_WINDOW
      expect(first_row.id).not_to eq(second_row.id)
      expect(first_row.reload).to have_attributes(group_count: 1, first_event_at: first_comment_at,
                                                  last_event_at: first_written_at)
      expect(second_row.reload).to have_attributes(group_count: 1, first_event_at: second_comment_at,
                                                   last_event_at: second_written_at)
      expect(second_comment_at).to be_between(first_row.first_event_at, first_row.last_event_at).exclusive
      expect([first_row, second_row]).to all(be_unread)

      # The span finds only rows without post ids. The first row carries its ids,
      # so reading the second comment neither loads nor locks it, however far
      # its span reaches.
      notifications = nil
      statements = capture_sql do
        _read, notifications = described_class.call(post: second_post, user: reader)
      end

      expect(statements.grep(/FROM "notifications".*FOR UPDATE/).size).to eq(1)
      expect(notifications).to contain_exactly(second_row)
      expect(second_row.reload).to be_state_read
      expect(first_row.reload).to be_unread

      _read, notifications = described_class.call(post: post_record, user: reader)

      expect(notifications).to contain_exactly(first_row)
      expect(first_row.reload).to be_state_read
    end

    # The first comment is read, and the reader marks its row unread again on
    # purpose. Reading the second comment answers the second comment only: its
    # receipt must not read the first row back, though the first row's span
    # covers it and the first post has a receipt of its own.
    it 'leaves a row the reader marked unread again unread when another comment is read' do
      first_row = row_written_by_fanout(post_record, commented_at: first_comment_at, written_at: first_written_at)
      second_row = row_written_by_fanout(second_post, commented_at: second_comment_at, written_at: second_written_at)
      expect(second_comment_at).to be_between(first_row.first_event_at, first_row.last_event_at).exclusive

      _read, notifications = described_class.call(post: post_record, user: reader)
      expect(notifications).to contain_exactly(first_row)
      result = Actors::ChangeNotificationState.call(notification: first_row.reload, change: 'unread',
                                                    current_user: reader)
      expect(result).to be_success
      expect(first_row.reload).to be_unread
      expect(second_row.reload).to be_unread

      _read, notifications = described_class.call(post: second_post, user: reader)

      expect(notifications).to contain_exactly(second_row)
      expect(second_row.reload).to be_state_read
      expect(first_row.reload).to be_unread
      expect(PostRead.where(post: post_record, user: reader)).to exist
    end
  end

  # A comment row from before payload.post_ids is found by its span. The key
  # missing, a JSON null and an empty list all leave a row without represented
  # posts, so each of them is such a row.
  {
    'without the key' => {},
    'with null' => { 'post_ids' => nil },
    'with an empty list' => { 'post_ids' => [] }
  }.each do |label, post_ids_payload|
    context "when a legacy row carries post_ids #{label}" do
      let!(:activity) do
        create(:activity, :post_added,
               organisation: organisation, actor: author, trackable: ticket,
               secondary: post_record, created_at: post_record.created_at)
      end

      def legacy_row(post_ids_payload, group_count: 1)
        row = create(:notification, :ticket_commented,
                     organisation: organisation, recipient: reader, actor: author,
                     notifiable: ticket, project: project, group_count: group_count,
                     payload: { 'activity_id' => SecureRandom.uuid }.merge(post_ids_payload),
                     first_event_at: activity.created_at - 1.second,
                     last_event_at: activity.created_at + 1.second)
        stored = Notification.where(id: row.id).pick(Arel.sql("(notifications.payload -> 'post_ids')::text"))
        expect(stored).to eq(post_ids_payload.key?('post_ids') ? post_ids_payload['post_ids'].to_json : nil)
        row
      end

      it 'reads a single row by the span of its events' do
        row = legacy_row(post_ids_payload)

        _read, notifications = described_class.call(post: post_record, user: reader)

        expect(notifications).to contain_exactly(row)
        expect(row.reload).to be_state_read
      end

      it 'keeps a group unread, as its posts are not known' do
        group = legacy_row(post_ids_payload, group_count: 2)

        _read, notifications = described_class.call(post: post_record, user: reader)

        expect(notifications).to be_empty
        expect(group.reload).to be_unread
      end
    end
  end
end
