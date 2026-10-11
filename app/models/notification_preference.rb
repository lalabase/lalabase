# frozen_string_literal: true

# The NotificationPreference model controls HOW users are notified.
#
# PURPOSE:
# Every user can configure which notifications they want to receive via which channel.
# Per event type and channel there is a simple toggle: on (immediate) or off (never).
#
# WHY BUILT THIS WAY:
# - Hierarchical system: global → organisation → project → item (more specific = more important)
# - Different channels can have different settings
# - Smart defaults: important things (mentions, assignments) are immediate by default
#
# EXAMPLE:
# User has global email=off, but for project "Website" email=on
# → No e-mails, except for Website updates

# == Schema Information
#
# Table name: notification_preferences
#
#  id              :uuid             not null, primary key
#  channel         :enum             default("in_app"), not null
#  enabled         :boolean          default(TRUE), not null
#  event_type      :enum             not null
#  frequency       :enum             default("daily"), not null
#  scope_type      :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid
#  scope_id        :uuid
#  user_id         :uuid             not null
#
# Indexes
#
#  idx_pref_lookup                                    (user_id,event_type,channel)
#  idx_pref_uniqueness                                (user_id,organisation_id,scope_type,scope_id,event_type,channel) UNIQUE
#  index_notification_preferences_on_organisation_id  (organisation_id)
#  index_notification_preferences_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
class NotificationPreference < ApplicationRecord
  # Include the module with the constants
  include Notifications::Constants

  # Associations
  belongs_to :user
  belongs_to :organisation, optional: true

  # Dynamic association for scope
  belongs_to :scope, polymorphic: true, optional: true, foreign_type: :scope_type

  # Enums
  # Build the enum map dynamically from the VALID_EVENT_TYPES constant
  enum :event_type, Notifications::Constants::VALID_EVENT_TYPES.index_by(&:to_sym), prefix: true

  enum :channel, {
    in_app: 'in_app',
    email: 'email'
  }, prefix: true

  enum :frequency, {
    immediate: 'immediate',
    daily: 'daily',
    weekly: 'weekly',
    never: 'never'
  }, prefix: true

  # Validations
  validates :user, presence: true
  validates :event_type, presence: true
  validates :channel, presence: true
  validates :frequency, presence: true
  validates :enabled, inclusion: { in: [true, false] }
  validates :event_type, uniqueness: {
    scope: %i[user_id organisation_id scope_type scope_id channel],
    message: :preference_exists
  }

  # Scopes
  scope :enabled, -> { where(enabled: true) }
  scope :disabled, -> { where(enabled: false) }
  scope :global, -> { where(scope_type: nil, scope_id: nil) }
  scope :for_organisation, ->(org) { where(organisation: org) }
  scope :for_scope, ->(scope) { where(scope_type: scope.class.name, scope_id: scope.id) }
  scope :for_project, ->(project) { where(scope_type: 'Project', scope_id: project.id) }
  scope :immediate_delivery, -> { frequency_immediate }

  # Callbacks
  after_create :create_default_preferences, if: :global_preference?

  # Class methods
  class << self
    # Main method for resolving NotificationPreferences with a hierarchical fallback system
    #
    # This method implements the hierarchical preference system:
    # 1. Item-specific (e.g. for a particular ticket)
    # 2. Project-specific (e.g. for a project)
    # 3. Organisation-specific (e.g. for an organisation)
    # 4. User-global (e.g. for all organisations)
    # 5. System default (if nothing is found)
    def resolve_for(user:, event_type:, channel:, scope: nil)
      # Build hierarchy of preference lookups
      preferences = []

      # Most specific: item-level preference
      if scope
        preferences << find_by(
          user: user,
          scope_type: scope.class.name,
          scope_id: scope.id,
          event_type: event_type,
          channel: channel
        )

        # Project-level preference (if scope is not already a project)
        if scope.respond_to?(:project) && scope.project
          preferences << find_by(
            user: user,
            scope_type: 'Project',
            scope_id: scope.project_id,
            event_type: event_type,
            channel: channel
          )
        end

        # Organisation-level preference
        if scope.respond_to?(:organisation)
          preferences << find_by(
            user: user,
            organisation: scope.organisation,
            scope_type: nil,
            scope_id: nil,
            event_type: event_type,
            channel: channel
          )
        end
      end

      # Organisation-level preference even when scope: nil
      current_organisation = if scope.respond_to?(:organisation)
                               scope.organisation
                             else
                               ActsAsTenant.current_tenant
                             end

      if current_organisation
        preferences << find_by(
          user: user,
          organisation: current_organisation,
          scope_type: nil,
          scope_id: nil,
          event_type: event_type,
          channel: channel
        )
      end

      # Global user preference
      preferences << find_by(
        user: user,
        organisation_id: nil,
        scope_type: nil,
        scope_id: nil,
        event_type: event_type,
        channel: channel
      )

      # Return the first preference found or create a default preference
      existing = preferences.compact.first

      if existing
        existing
      else
        Rails.logger.debug 'NotificationPreference default created: ' \
                          "user_id=#{user.id}, event_type=#{event_type}, channel=#{channel}, " \
                          "scope_type=#{scope&.class&.name}, scope_id=#{scope&.id}, " \
                          "organisation_id=#{scope.respond_to?(:organisation) ? scope.organisation&.id : nil}"

        create_default_for(
          user: user,
          event_type: event_type,
          channel: channel
        )
      end
    end

    def create_default_for(user:, event_type:, channel:)
      new(
        user: user,
        event_type: event_type,
        channel: channel,
        frequency: 'immediate',
        enabled: true
      )
    end

    def default_frequency_for(_event_type, _channel)
      'immediate'
    end
  end

  # Instance methods
  def should_deliver_now?
    enabled? && !frequency_never?
  end

  def global_preference?
    scope_type.nil? && scope_id.nil? && organisation_id.nil?
  end

  private

  def create_default_preferences
    # When creating a global preference, consider creating org/project specific ones
    # This is handled by a service object to avoid callback hell
  end
end
