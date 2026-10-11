# frozen_string_literal: true

module Notifications
  # The Suppressor decides whether a notification should be suppressed.
  #
  # PURPOSE:
  # Prevents notification spam through intelligent filters. Checks score,
  # user preferences and other factors to decide whether a notification is created.
  #
  # WHY BUILT THIS WAY:
  # - Score-Based: Unimportant notifications are filtered out
  # - Self-Action: Users get no notifications for their own actions
  # - Muted: Respects user preferences (enabled/frequency)
  #
  # Deduplication is ensured by GroupKeyBuilder + DB unique index.
  #
  # EXAMPLE:
  # User comments on their own ticket → suppressed (self-action)
  # Score 15 at threshold 20 → suppressed (low-score)

  class Suppressor
    # Include the module with the constants
    include Constants

    # Default score threshold - notifications below this are suppressed
    DEFAULT_SCORE_THRESHOLD = 20

    def initialize(activity, recipient, score = nil, channel = 'in_app', guaranteed: false, prefetched_preference: nil, prefetched_subscription: nil)
      @activity = activity
      @recipient = recipient
      @score = score
      @channel = channel
      @organisation = activity.organisation
      @guaranteed = guaranteed
      @prefetched_preference = prefetched_preference
      @prefetched_subscription = prefetched_subscription
      @reasons = []
    end

    def should_suppress?
      return true if suppress_self_action?
      return true if !@guaranteed && suppress_low_score?
      return true if suppress_muted?

      # Log suppression decision for analysis
      if @reasons.any?
        log_suppression
        return true
      end

      false
    end

    def suppression_reasons
      @reasons
    end

    private

    def suppress_self_action?
      return false unless @activity.actor == @recipient

      # Exception: System-initiated events should always reach the recipient,
      # even if they are technically the "actor" (e.g., scheduled reminders)
      return false if derive_event_type == EVENT_TYPE_SYSTEM_MESSAGE

      @reasons << :self_action
      true
    end

    def suppress_low_score?
      return false unless score_threshold_enabled?

      # Calculate score if not provided
      @score ||= ScoreCalculator.new(@activity, @recipient, @organisation).calculate

      if @score < score_threshold
        @reasons << :low_score
        return true
      end

      false
    end

    # Checks whether the user has "muted" this kind of notification
    #
    # IMPORTANT SEMANTICS: There are two kinds of "disabled":
    # 1. enabled = false: User has completely deactivated this event type
    # 2. frequency = 'never': User never wants to receive these events (even when enabled = true)
    #
    # WHY TWO MECHANISMS?
    # - enabled = false: "I'm not interested in ticket comments"
    # - frequency = 'never': "I am interested in ticket comments, but never show them to me in the app"
    #
    # This distinction is important for analytics and user understanding.
    def suppress_muted?
      # Fetch the preference for this event-type and channel combination
      preference = @prefetched_preference || NotificationPreference.resolve_for(
        user: @recipient,
        event_type: derive_event_type,
        channel: @channel, # CRITICAL FIX: Use the actual channel being processed
        scope: @activity.trackable
      )

      # CHECK 1: User has completely deactivated the event type
      if preference && !preference.enabled?
        @reasons << :muted_preference
        return true
      end

      # CHECK 2: User has set frequency to 'never'
      # This is a semantic extension — even when enabled=true,
      # frequency='never' means no notifications should be shown.
      #
      # CRITICAL: This was a bug — users could set frequency='never' but
      # still received in_app notifications because only 'enabled' was checked.
      if preference && preference.frequency == 'never'
        @reasons << :frequency_never
        return true
      end

      # Check if user has muted the specific item
      subscription = if !@prefetched_subscription.nil?
                       @prefetched_subscription
                     else
                       NotificationSubscription.find_by(
                         user: @recipient,
                         subscribable: @activity.trackable
                       )
                     end

      # NotificationSubscription uses mode enum, not level
      if subscription&.try(:mode_mute?)
        @reasons << :muted_subscription
        return true
      end

      false
    end

    def score_threshold_enabled?
      # Check if score-based suppression is enabled
      # Can be controlled via feature flag or org setting
      return true unless defined?(Flipper)

      Flipper.enabled?(:notification_score_threshold, @organisation)
    end

    def score_threshold
      # Allow customization per organisation
      @organisation.try(:notification_score_threshold) || DEFAULT_SCORE_THRESHOLD
    end

    def log_suppression
      Rails.logger.debug(
        "Notification suppressed: recipient_id=#{@recipient.id}, " \
        "activity_id=#{@activity.id}, reasons=#{@reasons.join(',')}, " \
        "score=#{@score}, organisation_id=#{@organisation.id}"
      )

      # Track metrics for monitoring
      track_suppression_metrics if defined?(StatsD)
    end

    def track_suppression_metrics
      @reasons.each do |reason|
        StatsD.increment("notifications.suppressed.#{reason}")
      end
      StatsD.increment('notifications.suppressed.total')
    rescue StandardError => e
      Rails.logger.error "Failed to track suppression metrics: #{e.message}"
    end

    def derive_event_type
      @derived_event_type ||= Notifications::Constants.derive_event_type(@activity.key, @activity.action)
    end
  end
end
