# frozen_string_literal: true

module Notifications
  # The GroupKeyBuilder creates intelligent group keys for notification grouping.
  #
  # PURPOSE:
  # Similar notifications are combined under a single group key. Instead of showing 5 separate
  # "Tim commented" messages, we show "Tim and 4 others commented".
  #
  # WHY BUILT THIS WAY:
  # - Time Window: Only events within 5 minutes are grouped
  # - Context-Aware: Groups only genuinely similar events (same context)
  # - User-Specific: Each user has their own groupings
  # - Atomic Updates: PostgreSQL advisory locks prevent race conditions
  #
  # EXAMPLE:
  # 3 comments on ticket #123 within 5 minutes
  # → Group Key: "ticket:123:commented:20240115-1400"
  # → Display: "Tim, Sarah and Max commented on ticket #123"

  class GroupKeyBuilder
    GROUP_TIME_WINDOW = 5.minutes
    MAX_GROUP_SIZE = 10
    MAX_LOCK_RETRIES = 3

    # Maps normalized action names to regex patterns that match raw action strings.
    ACTION_NORMALIZATIONS = {
      'commented' => /comment|reply|post/,
      'status_changed' => /status|state|transition/,
      'assigned' => /assign/,
      'document_added' => /attach|upload|document/
    }.freeze

    # Event types that can be grouped together in notifications.
    # Note: These compare notification.event_type with activity.action —
    # grouping only works when both values use the same naming convention.
    GROUPABLE_EVENT_SETS = [
      %w[ticket_commented ticket_replied ticket_posted post_added comment_added].freeze,
      %w[ticket_status_changed ticket_transitioned ticket_updated].freeze,
      %w[document_added file_uploaded attachment_added].freeze,
      %w[user_mentioned mentioned tagged].freeze
    ].freeze

    def initialize(activity, recipient, existing_groups: nil)
      @activity = activity
      @recipient = recipient
      @trackable = activity.trackable
      @existing_groups = existing_groups
    end

    def build
      [
        @trackable&.class&.name&.underscore,
        @trackable&.id,
        normalize_action(@activity.action),
        time_bucket
      ].compact.join(':')
    end

    def find_or_create_group(notification_params)
      group_key = build

      with_advisory_lock(group_key) do
        existing = find_existing_group(group_key, notification_params[:channel]) unless ungrouped_comment_email?(notification_params)

        if existing
          update_existing_group(existing, notification_params.merge(group_key: group_key))
        else
          create_new_group(notification_params.merge(group_key: group_key))
        end
      end
    end

    private

    def normalize_action(action)
      action_str = action.to_s

      ACTION_NORMALIZATIONS.each do |normalized, pattern|
        return normalized if action_str.match?(pattern)
      end

      action_str.downcase.gsub(/[^a-z0-9]/, '_')
    end

    def time_bucket
      bucket_seconds = GROUP_TIME_WINDOW.to_i
      bucket_start = (@activity.created_at.to_i / bucket_seconds) * bucket_seconds
      Time.at(bucket_start).strftime('%Y%m%d-%H%M')
    end

    def find_existing_group(group_key, channel)
      if @existing_groups
        cached = @existing_groups[[@recipient.id, group_key, channel.to_s]]
        return cached if cached
      end

      Notification
        .where(recipient: @recipient, group_key: group_key)
        .where(channel: channel)
        .where('created_at > ?', GROUP_TIME_WINDOW.ago)
        .where('group_count < ?', MAX_GROUP_SIZE)
        .order(created_at: :desc)
        .first
    end

    def can_add_to_group?(notification)
      return false if notification.group_count >= MAX_GROUP_SIZE
      return false if notification.created_at < GROUP_TIME_WINDOW.ago
      return false if notification.state_read? || notification.state_archived?
      # Once an email has left the queue its content is immutable. Reusing a
      # sent row would append a comment that was never present in the delivered
      # message, while the delivery job correctly refuses to send the row twice.
      return false if notification.channel_email? && !notification.state_queued?
      return false if notification.priority_critical? || notification.priority_high?

      similar_context?(notification)
    end

    def similar_context?(notification)
      return false unless notification.notifiable_type == @trackable&.class&.name
      return false unless notification.notifiable_id == @trackable&.id

      compatible_event_types?(notification.event_type, @activity.action)
    end

    def compatible_event_types?(existing_type, new_type)
      existing_str = existing_type.to_s
      new_str = new_type.to_s

      return true if existing_str == new_str

      GROUPABLE_EVENT_SETS.any? do |set|
        set.include?(existing_str) && set.include?(new_str)
      end
    end

    def update_existing_group(notification, new_params)
      notification.with_lock do
        # State can change after lookup (read/archive/email delivery). Recheck
        # while holding the row lock before mutating the group.
        return create_new_group(new_params) unless can_add_to_group?(notification) && complete_post_group?(notification, new_params)

        notification.group_count += 1
        notification.last_event_at = @activity.created_at
        merge_actors(notification, new_params[:actor_id] || new_params[:actor]&.id)
        merge_payload(notification, new_params[:payload])
        notification.state = :queued if notification.state_read?
        notification.save!
      end

      notification
    end

    # Email content can be rendered while its lifecycle row is still queued.
    # A later post must therefore get its own immutable email row; otherwise a
    # concurrent group update could claim content the recipient never received.
    def ungrouped_comment_email?(notification_params)
      return false unless notification_params[:channel].to_s == 'email'

      payload = notification_params[:payload] || {}
      Array(payload[:post_ids] || payload['post_ids']).any?
    end

    # Never turn a legacy group into a partially enumerated post group: doing
    # so would let a receipt for the new post consume its older unread comments.
    def complete_post_group?(notification, new_params)
      payload = new_params[:payload] || {}
      incoming_ids = Array(payload[:post_ids] || payload['post_ids'])
      existing_ids = Array(notification.payload['post_ids'])
      incoming_ids.empty? == existing_ids.empty?
    end

    def create_new_group(params)
      project = determine_project

      Notification.create!(
        params.merge(
          group_count: 1,
          first_event_at: @activity.created_at,
          last_event_at: @activity.created_at,
          dedupe_fingerprint: generate_dedupe_fingerprint(params),
          project: project
        )
      )
    end

    def determine_project
      return nil unless @trackable

      if @trackable.is_a?(Project)
        @trackable
      elsif @trackable.respond_to?(:project)
        @trackable.project
      elsif @trackable.respond_to?(:ticket)
        @trackable.ticket&.project
      end
    end

    def merge_actors(notification, new_actor_id)
      actors = (notification.payload['actor_ids'] || []).dup
      actors << notification.actor_id if notification.actor_id
      actors << new_actor_id if new_actor_id
      notification.payload['actor_ids'] = actors.uniq.compact
      notification.actor_id = new_actor_id if new_actor_id
    end

    def merge_payload(notification, new_payload)
      return unless new_payload

      notification.payload ||= {}

      new_payload.each do |key, value|
        key = key.to_s
        existing = notification.payload[key]

        notification.payload[key] = if existing.is_a?(Array) && value.is_a?(Array)
                                      (existing + value).uniq
                                    elsif existing.is_a?(Array)
                                      (existing + [value]).uniq
                                    elsif value.is_a?(Array)
                                      ([existing] + value).compact.uniq
                                    else
                                      value
                                    end
      end
    end

    def generate_dedupe_fingerprint(params)
      components = [
        @activity.id,
        params[:recipient_id],
        params[:notifiable_type],
        params[:notifiable_id],
        params[:event_type],
        params[:channel]
      ]

      Digest::SHA256.hexdigest(components.compact.join(':'))
    end

    def with_advisory_lock(key)
      lock_key = "notification_group:#{key}"
      lock_id = Digest::SHA1.hexdigest(lock_key).hex % (2**31 - 1)
      connection = ActiveRecord::Base.connection

      retries = 0
      begin
        acquired = connection.execute(
          "SELECT pg_try_advisory_lock(#{lock_id})"
        ).first['pg_try_advisory_lock']

        raise LockTimeoutError, "Could not acquire advisory lock for #{key}" unless acquired

        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{lock_id})")
        end
      rescue LockTimeoutError
        retries += 1
        if retries <= MAX_LOCK_RETRIES
          Rails.logger.warn(
            "GroupKeyBuilder: Lock timeout for #{lock_key}, retry #{retries}/#{MAX_LOCK_RETRIES}"
          )
          sleep(rand(0.1..0.5))
          retry
        else
          Rails.logger.error(
            "GroupKeyBuilder: Failed to acquire lock after #{MAX_LOCK_RETRIES} retries for #{lock_key}"
          )
          raise LockFailedError, "Could not acquire lock for group key: #{key}"
        end
      end
    end
  end

  class LockTimeoutError < StandardError; end
  class LockFailedError < StandardError; end
end
