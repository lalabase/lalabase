# frozen_string_literal: true

# Records durable per-post read receipts and consumes matching comment
# notifications. Deleting a reaction deliberately does not undo the receipt.
module Posts
  class MarkRead
    def self.call(post:, user:)
      new(post:, user:).call
    end

    def initialize(post:, user:)
      @post = post
      @user = user
    end

    def call
      PostRead.synchronize(post_id: post.id) { record_read }
    end

    private

    attr_reader :post, :user

    def record_read
      now = Time.current
      PostRead.insert_all(
        [{
          organisation_id: post.organisation_id,
          post_id: post.id,
          user_id: user.id,
          read_at: now,
          created_at: now,
          updated_at: now
        }],
        unique_by: 'index_post_reads_on_post_user'
      )
      read = PostRead.find_by!(post: post, user: user)

      [read, mark_matching_notifications]
    end

    def mark_matching_notifications
      base = user.notifications
                 .unread
                 .channel_in_app
                 .where(
                   organisation: post.organisation,
                   notifiable: post.ticket,
                   event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED
                 )

      activities = Activity.where(action: 'post_added', secondary: post).pluck(:id, :created_at)
      matching = base.where('notifications.payload @> ?', { post_ids: [post.id.to_s] }.to_json)

      if activities.any?
        activity_ids = activities.map { |id, _created_at| id.to_s }
        activity_times = activities.map(&:second)
        matching = matching.or(base.where("notifications.payload ->> 'activity_id' IN (?)", activity_ids))

        # Older grouped notifications predate payload.post_ids. Their scalar
        # activity_id points only at the newest comment in the group, so the
        # group's first/last event interval is the reliable compatibility seam.
        activity_times.each do |created_at|
          matching = matching.or(base.where('first_event_at <= ? AND last_event_at >= ?', created_at, created_at))
        end
      end

      matching.distinct.filter_map { |notification| mark_if_fully_read(notification) }
    end

    # Grouping and reactions can run in separate jobs. Locking and reloading the
    # row makes the payload we evaluate the same payload we mark as read: if a
    # new comment joins the group concurrently, it cannot be swallowed by a
    # decision based on the older payload.
    def mark_if_fully_read(notification)
      notification.with_lock do
        post_ids = notification_post_ids(notification)
        return if post_ids.empty? && notification.grouped?
        return unless post_ids.empty? || all_posts_read?(post_ids)

        notification.mark_as_read!
        notification
      end
    end

    def all_posts_read?(post_ids)
      PostRead.all_existing_posts_read?(
        organisation: post.organisation,
        user: user,
        post_ids: post_ids
      )
    end

    def notification_post_ids(notification)
      Array(notification.payload['post_ids']).map(&:to_s).uniq
    end
  end
end
