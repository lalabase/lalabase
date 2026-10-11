# frozen_string_literal: true

# The NotificationSubscription model controls WHAT users actively follow.
#
# PURPOSE:
# Simple on/off per ticket. Users can explicitly
# "watch" (follow) or "mute" tickets.
#
# SEMANTICS:
# - follow: ticket is "switched on" - user receives notifications
# - mute: explicit opt-out - survives auto-subscribe attempts
# - No record: not subscribed - auto-subscribe can create one
#
# AUTO-SUBSCRIBE RULES:
# - Ticket assignment → auto follow (unless a mute exists)
# - Ticket creation → auto follow (if the user setting is enabled)
# - Ticket unassignment → auto unfollow (unless manual or creator)

# == Schema Information
#
# Table name: notification_subscriptions
#
#  id                :uuid             not null, primary key
#  mode              :enum             default("follow"), not null
#  source            :string
#  subscribable_type :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid             not null
#  subscribable_id   :uuid             not null
#  subscribed_by_id  :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  idx_subscription_lookup                               (subscribable_type,subscribable_id)
#  idx_subscription_uniqueness                           (user_id,subscribable_type,subscribable_id) UNIQUE
#  index_notification_subscriptions_on_organisation_id   (organisation_id)
#  index_notification_subscriptions_on_subscribed_by_id  (subscribed_by_id)
#  index_notification_subscriptions_on_user_id           (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (subscribed_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
class NotificationSubscription < ApplicationRecord
  SOURCE_CREATOR  = 'creator'
  SOURCE_ASSIGNEE = 'assignee'
  SOURCE_SELF     = 'self'
  SOURCE_MANUAL   = 'manual'
  VALID_SOURCES   = [SOURCE_CREATOR, SOURCE_ASSIGNEE, SOURCE_SELF, SOURCE_MANUAL].freeze
  SOURCES         = VALID_SOURCES

  # Multi-tenancy
  acts_as_tenant(:organisation)

  # Associations
  belongs_to :user
  belongs_to :subscribable, polymorphic: true
  belongs_to :subscribed_by, class_name: 'User', optional: true

  # Enums - immediate still defined for DB compatibility but no longer actively used
  enum :mode, {
    follow: 'follow',
    mute: 'mute',
    immediate: 'immediate'
  }, prefix: true

  # Validations
  validates :user, presence: true
  validates :subscribable_type, presence: true
  validates :subscribable_id, presence: true
  validates :mode, presence: true
  validates :user_id, uniqueness: {
    scope: %i[subscribable_type subscribable_id],
    message: :subscription_exists
  }

  validates :source, inclusion: { in: VALID_SOURCES }, allow_nil: true

  validate :validate_subscribable_exists
  validate :validate_user_has_access
  validate :validate_subscribed_by_for_manual

  # Scopes
  scope :active, -> { where.not(mode: :mute) }
  scope :muted, -> { mode_mute }
  scope :following, -> { mode_follow }
  scope :for_user, ->(user) { where(user: user) }
  scope :for_item, ->(item) { where(subscribable: item) }
  scope :for_tickets, -> { where(subscribable_type: 'Ticket') }
  scope :for_projects, -> { where(subscribable_type: 'Project') }
  scope :visible, -> { where.not(mode: :mute) }
  # user carries the avatar blob: the subscriber pills render the name circle
  # in circle mode, whose attached? check is one query per subscriber otherwise.
  scope :with_subscribers, -> { includes(:subscribed_by, user: { avatar_attachment: :blob }) }

  # Callbacks
  after_create_commit :notify_subscription_created
  after_update_commit :notify_subscription_updated, if: :saved_change_to_mode?
  after_destroy_commit :notify_subscription_destroyed

  # Class methods
  class << self
    def find_or_initialize_for(user:, item:)
      ActsAsTenant.with_tenant(item.organisation) do
        find_or_initialize_by(
          user: user,
          subscribable: item
        )
      end
    end

    # Simple on/off toggle for ticket notifications.
    #
    # - No subscription → creates follow (ON)
    # - follow → turns OFF (mute if auto-rules say ON, destroy otherwise)
    # - mute → updates to follow (ON)
    # - Explicit mode parameter overrides toggle behavior
    def toggle_for(user:, item:, mode: nil)
      subscription = find_by(user: user, subscribable: item)

      if mode
        set_explicit_mode(user, item, subscription, mode)
      elsif subscription&.mode_follow? || subscription&.mode_immediate?
        turn_off(user, item, subscription)
      elsif subscription&.mode_mute?
        subscription.update!(mode: 'follow')
        subscription
      else
        create_follow(user, item)
      end
    end

    # Determines if auto-subscribe rules would create a subscription for this user/item.
    # Used to decide between mute (explicit opt-out) vs destroy (just not interested).
    def auto_would_subscribe?(user, item)
      return false unless item.is_a?(Ticket)

      item.assignee_ids.include?(user.id) ||
        (item.creator_id == user.id && user.ticket_auto_follow_created?)
    end

    # System-initiated subscription that bypasses validate_user_has_access.
    # Used by auto-subscribe callbacks (assignment, creation, comment authorship)
    # where the system guarantees the user should have access.
    #
    # Returns the subscription or nil if user has explicitly muted.
    def system_subscribe(user:, item:, mode: 'follow', source: nil)
      existing = find_by(user: user, subscribable: item)
      return existing if existing&.mode == mode
      return nil if existing&.mode_mute?

      if existing
        existing.update_column(:mode, mode)
        existing
      else
        sub = new(
          user: user,
          subscribable: item,
          organisation: item.organisation,
          mode: mode
        )
        sub.source = source if source.present?
        sub.save!(validate: false)
        sub
      end
    rescue ActiveRecord::RecordNotUnique
      find_by(user: user, subscribable: item)
    end

    def subscribe_other(user:, item:, subscribed_by:)
      existing = find_by(user: user, subscribable: item)
      return nil if existing&.mode_mute?

      sub = existing || new(
        user: user,
        subscribable: item,
        organisation: item.organisation
      )
      sub.mode = :follow
      sub.source = SOURCE_MANUAL
      sub.subscribed_by = subscribed_by
      sub.save!
      sub
    end

    def bulk_subscribe(users:, item:, mode: 'follow')
      ActiveRecord::Base.transaction do
        users.map do |user|
          find_or_create_by!(
            user: user,
            subscribable: item,
            mode: mode
          )
        end
      end
    end

    def auto_subscribe_assignees(ticket)
      return unless ticket.is_a?(Ticket)

      ticket.ticket_assignments.includes(:user).find_each do |assignment|
        system_subscribe(user: assignment.user, item: ticket)
      end
    end

    private

    def set_explicit_mode(user, item, subscription, mode)
      if mode == 'follow'
        sub = find_or_initialize_for(user: user, item: item)
        sub.mode = 'follow'
        sub.save!
        sub
      elsif mode == 'mute'
        sub = find_or_initialize_for(user: user, item: item)
        sub.mode = 'mute'
        sub.save!
        sub
      else
        subscription&.destroy
        nil
      end
    end

    def turn_off(user, item, subscription)
      if auto_would_subscribe?(user, item)
        # Auto-rules say ON, so create explicit opt-out (mute)
        subscription.update!(mode: 'mute')
        subscription
      else
        subscription.destroy
        nil
      end
    end

    def create_follow(user, item)
      sub = find_or_initialize_for(user: user, item: item)
      sub.mode = 'follow'
      sub.source = SOURCE_SELF
      sub.save!
      sub
    end
  end

  # Instance methods
  def active?
    !mode_mute?
  end

  def watching?
    mode_follow?
  end

  def notification_frequency_override
    return 'never' if mode_mute?

    nil # Use user's default preferences
  end

  private

  def validate_subscribable_exists
    return if subscribable_type.blank? || subscribable_id.blank?

    klass = subscribable_type.safe_constantize
    return errors.add(:subscribable_type, :invalid) unless klass

    return if klass.exists?(subscribable_id)

    errors.add(:subscribable_id, :does_not_exist)
  end

  def validate_user_has_access
    return unless subscribable && user

    case subscribable
    when Ticket
      errors.add(:base, :no_ticket_access) unless user.can_view_ticket?(subscribable)
    when Project
      errors.add(:base, :no_project_access) unless user.can_view_project?(subscribable)
    end
  rescue NoMethodError
    # If can_view methods don't exist yet, skip validation
  end

  def notify_subscription_created
    # Could trigger a notification that user is now following
  end

  def notify_subscription_updated
    Rails.logger.debug "Subscription updated: User #{user_id} changed mode to #{mode} for #{subscribable_type} #{subscribable_id}"
  end

  def notify_subscription_destroyed
    Rails.logger.debug "Subscription removed: User #{user_id} unsubscribed from #{subscribable_type} #{subscribable_id}"
  end

  def validate_subscribed_by_for_manual
    return unless source == SOURCE_MANUAL && subscribed_by_id.blank?

    errors.add(:subscribed_by, :blank)
  end
end
