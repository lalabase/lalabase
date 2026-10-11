# frozen_string_literal: true

# Side-effect chain map: docs/architektur/seiteneffekt_ketten.md
#
# The OutboxEvent model ensures that no notifications get lost.
#
# PURPOSE:
# When an Activity is created, an OutboxEvent is created at the same time (in the same database
# transaction). A background worker later processes these events into notifications.
# This way no notifications are lost even when the system crashes.
#
# WHY BUILT THIS WAY:
# - Transactional Outbox Pattern: Activity + OutboxEvent in the same DB transaction = guaranteed consistent
# - Retry logic with exponential backoff: 1min, 5min, 15min, 1h, 3h, ... up to 72h
# - Event type mapping: activities have technical names, notifications have user-facing names
# - Processing locks prevent duplicate processing across multiple workers
#
# EXAMPLE:
# Activity "ticket.updated" is created → OutboxEvent is created
# → worker processes the event → creates "ticket_status_changed" notifications for relevant users

# == Schema Information
#
# Table name: outbox_events
#
#  id              :uuid             not null, primary key
#  available_at    :datetime         not null
#  error_message   :string
#  event_type      :string           not null
#  payload         :jsonb            not null
#  processed_at    :datetime
#  retry_count     :integer          default(0)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  activity_id     :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_outbox_processing                   (available_at,processed_at)
#  index_outbox_events_on_activity_id      (activity_id)
#  index_outbox_events_on_organisation_id  (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (activity_id => activities.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
class OutboxEvent < ApplicationRecord
  # Include the module with the constants
  include Notifications::Constants

  # Constants
  MAX_RETRY_COUNT = 10
  RETRY_DELAYS = [
    1.minute,
    5.minutes,
    15.minutes,
    1.hour,
    3.hours,
    6.hours,
    12.hours,
    24.hours,
    48.hours,
    72.hours
  ].freeze

  # Multi-tenancy
  acts_as_tenant(:organisation)

  # Associations
  belongs_to :activity

  # Validations
  validates :event_type, presence: true
  validates :payload, presence: true
  validates :available_at, presence: true
  validates :retry_count, numericality: { greater_than_or_equal_to: 0 }

  # Scopes
  scope :pending, -> { where(processed_at: nil) }
  scope :processed, -> { where.not(processed_at: nil) }
  scope :available, -> { pending.where('available_at <= ?', Time.current) }
  scope :failed, -> { where.not(error_message: nil) }
  scope :stuck, -> { pending.where('created_at < ?', 1.hour.ago) }
  scope :retriable, -> { failed.where('retry_count < ?', MAX_RETRY_COUNT) }
  scope :recent, -> { order(created_at: :desc) }
  scope :oldest_first, -> { order(available_at: :asc, created_at: :asc) }

  # Callbacks
  before_validation :set_defaults, on: :create
  after_create_commit :schedule_processing

  # Class methods
  class << self
    def create_from_activity!(activity)
      return unless should_create_notifications?(activity)

      event_type = derive_event_type(activity)
      return unless event_type

      create!(
        activity: activity,
        organisation: ActsAsTenant.current_tenant || activity.organisation,
        event_type: event_type,
        payload: build_payload(activity),
        available_at: Time.current
      )
    end

    def process_available(batch_size: 100)
      available.oldest_first.limit(batch_size).each do |event|
        event.process!
      rescue StandardError => e
        Rails.logger.error "Failed to process outbox event #{event.id}: #{e.message}"
        event.mark_failed(e.message)
      end
    end

    def cleanup_old_processed(days_ago: 7)
      processed.where('processed_at < ?', days_ago.days.ago).destroy_all
    end

    def retry_failed
      retriable.find_each(&:retry!)
    end

    private

    def should_create_notifications?(activity)
      # Only check system_user? if actor is already loaded (avoids unnecessary DB query;
      # system_user? is not defined on User, so this is purely defensive)
      return false if activity.association(:actor).loaded? && activity.actor.respond_to?(:system_user?) && activity.actor.system_user?

      # Skip if activity is marked to skip notifications
      return false if activity.parameters&.dig('skip_notifications')

      # Skip certain activity types that shouldn't notify
      skip_actions = %w[viewed exported downloaded]
      return false if skip_actions.include?(activity.action)

      true
    rescue NoMethodError
      true # Default to creating notifications if methods don't exist
    end

    def derive_event_type(activity)
      Notifications::Constants.derive_event_type(activity.key, activity.action)
    end

    def build_payload(activity)
      {
        activity_id: activity.id,
        actor_id: activity.actor_id,
        trackable_type: activity.trackable_type,
        trackable_id: activity.trackable_id,
        action: activity.action,
        parameters: activity.parameters || {},
        attribute_changes: activity.attribute_changes || {},
        created_at: activity.created_at.iso8601
      }
    end
  end

  # Instance methods
  def notifiable
    activity.trackable
  end

  def process!
    return if processed?

    ActiveRecord::Base.transaction do
      # Lock the row to prevent concurrent processing
      with_lock do
        return if processed?

        # Process the event
        result = process_event

        if result[:success]
          mark_processed!
        else
          mark_failed(result[:error])
        end
      end
    end
  end

  def retry!
    return unless can_retry?

    update!(
      available_at: next_retry_time,
      retry_count: retry_count + 1,
      error_message: nil
    )

    schedule_processing
  end

  def mark_processed!
    update!(processed_at: Time.current, error_message: nil)
  end

  def mark_failed(error_msg)
    update!(
      error_message: error_msg&.truncate(500)
    )

    retry! if can_retry?
  end

  def processed?
    processed_at.present?
  end

  def failed?
    error_message.present?
  end

  def can_retry?
    retry_count < MAX_RETRY_COUNT
  end

  def stuck?
    !processed? && created_at < 1.hour.ago
  end

  def next_retry_time
    delay = RETRY_DELAYS[retry_count] || RETRY_DELAYS.last
    Time.current + delay
  end

  private

  def set_defaults
    self.available_at ||= Time.current
    self.payload ||= {}
    self.retry_count ||= 0
  end

  def schedule_processing
    # Schedule the processing job using Solid Queue
    OutboxConsumeJob.set(wait_until: available_at).perform_later(id)
  rescue StandardError => e
    Rails.logger.error "Failed to schedule outbox event processing: #{e.message}"
  end

  def process_event
    # This is where the actual notification fanout happens
    Notifications::FanoutService.new(self).call
  rescue StandardError => e
    Rails.logger.error "Failed to process outbox event: #{e.message}"
    { success: false, error: e.message }
  end
end
