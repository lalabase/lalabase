# frozen_string_literal: true

module Notifications
  # The ScoreCalculator computes a relevance score (0-100) for notifications.
  #
  # PURPOSE:
  # Every notification gets a score that determines how important it is for the user.
  # Higher score = more important notification. Used for filtering and prioritization.
  #
  # WHY BUILT THIS WAY:
  # - Event-Type Weights: Some events are inherently more important (e.g. mentions)
  # - Proximity Bonus: Direct involvement raises the score
  # - Subscription Bonus: Users who explicitly "watch" something get a higher score
  # - Recency Decay: Older events get a lower score
  # - Organisational Priority: Teams can set their own weightings
  #
  # EXAMPLE:
  # Mention in your own ticket: Base 70 + Proximity 20 + Recent 10 = Score 100
  # Comment in someone else's ticket: Base 30 + Watch 10 = Score 40

  class ScoreCalculator
    # Include the module with the constants
    include Constants

    # Score configuration for the various event types
    # Use fully qualified names for better autoloading stability
    EVENT_TYPE_SCORES = {
      Notifications::Constants::EVENT_TYPE_MENTION => 70,
      Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED => 65,
      Notifications::Constants::EVENT_TYPE_TICKET_UNASSIGNED => 65,
      Notifications::Constants::EVENT_TYPE_TICKET_BLOCKER => 60,
      Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT => 50,
      Notifications::Constants::EVENT_TYPE_TICKET_STATUS_CHANGED => 40,
      Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED => 30,
      Notifications::Constants::EVENT_TYPE_DOCUMENT_ADDED => 25,
      Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE => 80
    }.freeze

    DEFAULT_EVENT_SCORE = 30

    # Bonus points for different proximity levels
    PROXIMITY_BONUSES = {
      creator: 20,      # User created the item
      assignee: 20,     # User is assigned to the item
      mentioned: 25,    # User was mentioned
      participant: 10,  # User has participated (commented etc.)
      watcher: 10,      # User is watching/following
      team_member: 5    # User is in the same project/team
    }.freeze

    # Time-based decay factors
    RECENCY_BONUSES = {
      immediate: 10,    # < 1 hour ago
      recent: 5,        # < 24 hours ago
      moderate: 2,      # < 7 days ago
      old: 0 # > 7 days ago
    }.freeze

    def initialize(activity, recipient, organisation = nil)
      @activity = activity
      @recipient = recipient
      @organisation = organisation || @activity.organisation
      @trackable = @activity.trackable
      @actor = @activity.actor
    end

    def calculate
      score = base_score + proximity_bonus + subscription_bonus + recency_bonus

      # Apply organisation-specific adjustments if configured
      score = apply_org_adjustments(score)

      # Ensure score is within valid range
      [[score, 100].min, 0].max
    end

    private

    def base_score
      # CRITICAL BUG FIX: Use derive_event_type instead of @activity.action
      # The action is the raw activity action ('updated'), not the mapped event type
      event_type = derive_event_type_for_scoring

      # Validate against central constants
      unless VALID_EVENT_TYPES.include?(event_type)
        Rails.logger.warn "ScoreCalculator: Invalid event type '#{event_type}', using system_message"
        event_type = Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE
      end

      EVENT_TYPE_SCORES.fetch(event_type, DEFAULT_EVENT_SCORE)
    end

    def proximity_bonus
      bonus = 0

      # Check if recipient created the item
      bonus += PROXIMITY_BONUSES[:creator] if trackable_created_by_recipient?

      # Check if recipient is assigned
      bonus += PROXIMITY_BONUSES[:assignee] if trackable_assigned_to_recipient?

      # Check if recipient was mentioned
      bonus += PROXIMITY_BONUSES[:mentioned] if mentioned?

      # Check if recipient has participated
      bonus += PROXIMITY_BONUSES[:participant] if participant?

      # Check if recipient is a team member
      bonus += PROXIMITY_BONUSES[:team_member] if team_member?

      bonus
    end

    def subscription_bonus
      # Check if user has an explicit subscription to this item
      subscription = find_subscription

      return 0 unless subscription

      # Use central constants for subscription modes
      mode = subscription.try(:mode) || subscription.try(:level)

      if Notifications::Constants::HIGH_ENGAGEMENT_MODES.include?(mode)
        PROXIMITY_BONUSES[:watcher] * 2 # Double bonus for immediate watchers
      elsif Notifications::Constants::NORMAL_ENGAGEMENT_MODES.include?(mode)
        PROXIMITY_BONUSES[:watcher]
      elsif Notifications::Constants::MUTED_MODES.include?(mode)
        -50 # Heavily penalize muted items
      else
        0
      end
    end

    def recency_bonus
      time_ago = Time.current - @activity.created_at

      case time_ago
      when 0..1.hour
        RECENCY_BONUSES[:immediate]
      when 1.hour..24.hours
        RECENCY_BONUSES[:recent]
      when 24.hours..7.days
        RECENCY_BONUSES[:moderate]
      else
        RECENCY_BONUSES[:old]
      end
    end

    def mentioned?
      # Check if activity has parameters (Activities use parameters, not payload)
      return false unless @activity.respond_to?(:parameters) && @activity.parameters

      # Check various parameter fields for mentions
      mention_fields = %w[mentioned_users mentions mentioned_user_ids]

      mention_fields.any? do |field|
        value = @activity.parameters[field]
        next false unless value

        case value
        when Array
          value.include?(@recipient.id) || value.include?(@recipient.email)
        when String
          value.include?(@recipient.email)
        else
          false
        end
      end
    end

    def participant?
      return false unless @trackable

      # Cached to avoid repeated DB queries in batch scenarios
      @participant ||= Activity.where(
        trackable: @trackable,
        actor: @recipient
      ).exists?
    end

    def team_member?
      return false unless @trackable

      # Check if user has access to the project
      if @trackable.respond_to?(:project)
        project = @trackable.project
      elsif @trackable.is_a?(Project)
        project = @trackable
      else
        return false
      end

      return false unless project

      # Check if user has any permissions on this project
      @recipient.can_access_project?(project, :read, :tickets)
    rescue StandardError
      false
    end

    def find_subscription
      return nil unless @trackable

      # Try to find a subscription for this specific item
      NotificationSubscription
        .where(user: @recipient, subscribable: @trackable)
        .or(
          # Also check for project-level subscriptions if trackable belongs to a project
          NotificationSubscription.where(
            user: @recipient,
            subscribable: @trackable.try(:project)
          )
        )
        .order(created_at: :desc)
        .first
    rescue StandardError
      nil
    end

    def apply_org_adjustments(score)
      # Future: Allow organisations to configure custom score adjustments
      # For now, just return the score as-is

      # Example future implementation:
      # if @organisation.notification_settings['score_adjustments']
      #   adjustments = @organisation.notification_settings['score_adjustments']
      #   score = score * (adjustments['multiplier'] || 1.0)
      #   score = score + (adjustments['offset'] || 0)
      # end

      score
    end

    def trackable_created_by_recipient?
      return false unless @trackable

      # Check various creator-like attributes that might exist
      creator_methods = %i[creator author user created_by]

      creator_methods.any? do |method|
        if @trackable.respond_to?(method)
          creator = @trackable.send(method)
          creator == @recipient
        else
          false
        end
      end
    end

    def trackable_assigned_to_recipient?
      return false unless @trackable

      # Check for single assignee
      if @trackable.respond_to?(:assignee)
        assignee = @trackable.assignee
        return true if assignee == @recipient
      end

      # Check for multiple assignees
      if @trackable.respond_to?(:assignees)
        assignees = @trackable.assignees
        return true if assignees&.include?(@recipient)
      end

      # Check for assigned_to field
      if @trackable.respond_to?(:assigned_to)
        assigned_to = @trackable.assigned_to
        return true if assigned_to == @recipient
      end

      # Check for assigned_users association (many-to-many)
      if @trackable.respond_to?(:assigned_users)
        assigned_users = @trackable.assigned_users
        return true if assigned_users&.include?(@recipient)
      end

      false
    end

    def derive_event_type_for_scoring
      @derived_event_type ||= Notifications::Constants.derive_event_type(@activity.key, @activity.action)
    end
  end
end
