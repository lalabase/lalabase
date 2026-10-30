# frozen_string_literal: true

# == Schema Information
#
# Table name: user_activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  category          :string           not null
#  failure_reason    :text
#  ip_address        :string
#  metadata          :jsonb
#  status            :string           default("success")
#  trackable_type    :string
#  user_agent        :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid
#  session_id        :string
#  trackable_id      :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  idx_user_activities_on_category_and_time  (category,created_at)
#  idx_user_activities_on_created_at         (created_at)
#  idx_user_activities_on_ip_and_time        (ip_address,created_at)
#  idx_user_activities_on_org_and_time       (organisation_id,created_at)
#  idx_user_activities_on_session            (session_id)
#  idx_user_activities_on_trackable          (trackable_type,trackable_id)
#  idx_user_activities_on_user_action_time   (user_id,action,created_at)
#  idx_user_activities_on_user_and_time      (user_id,created_at)
#  index_user_activities_on_organisation_id  (organisation_id)
#  index_user_activities_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
class UserActivity < ApplicationRecord
  # Constants for activity types
  ACTIONS = {
    # Authentication
    login: 'login',
    logout: 'logout',
    login_failed: 'login_failed',

    # Account Management
    registered: 'registered',
    password_reset_requested: 'password_reset_requested',
    password_reset_completed: 'password_reset_completed',
    email_changed: 'email_changed',
    profile_updated: 'profile_updated',
    account_locked: 'account_locked',
    account_unlocked: 'account_unlocked',

    # Permissions
    role_assigned: 'role_assigned',
    role_removed: 'role_removed',
    permissions_changed: 'permissions_changed',
    project_access_granted: 'project_access_granted',
    project_access_revoked: 'project_access_revoked',

    # Invitations
    invitation_sent: 'invitation_sent',
    invitation_accepted: 'invitation_accepted',
    invitation_declined: 'invitation_declined',

    # Security
    api_token_created: 'api_token_created',
    api_token_deleted: 'api_token_deleted',
    suspicious_activity: 'suspicious_activity',

    # GDPR data export (Art. 15/20)
    data_export_requested: 'data_export_requested',
    data_export_downloaded: 'data_export_downloaded'
  }.freeze

  CATEGORIES = {
    auth: 'auth',
    profile: 'profile',
    permissions: 'permissions',
    security: 'security',
    invitations: 'invitations'
  }.freeze

  STATUSES = {
    success: 'success',
    failed: 'failed',
    pending: 'pending'
  }.freeze

  # Associations
  belongs_to :user
  belongs_to :organisation, optional: true
  belongs_to :trackable, polymorphic: true, optional: true

  # Validations
  validates :action, presence: true, inclusion: { in: ACTIONS.values }
  validates :category, presence: true, inclusion: { in: CATEGORIES.values }
  validates :status, inclusion: { in: STATUSES.values }

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :for_organisation, ->(org) { where(organisation: org) }
  scope :for_category, ->(category) { where(category: category) }
  scope :for_action, ->(action) { where(action: action) }
  scope :successful, -> { where(status: STATUSES[:success]) }
  scope :failed, -> { where(status: STATUSES[:failed]) }

  # Time-based scopes
  scope :today, -> { where(created_at: Date.current.all_day) }
  # Time.current, not Date.current: Date#end_of_week is a DATE, and Rails binds it as
  # midnight, so the whole last day of the week fell outside the range. The scope was
  # correct six days out of seven and silently wrong on the seventh - which is also why
  # its spec only went red on a Sunday. Time#all_week ends at 23:59:59.999999, the same
  # shape the :today scope beside it already had via Date#all_day.
  scope :this_week, -> { where(created_at: Time.current.all_week) }
  scope :this_month, -> { where(created_at: Time.current.all_month) }
  scope :between, ->(start_date, end_date) { where(created_at: start_date..end_date) }

  # Category scopes
  scope :auth_activities, -> { for_category(CATEGORIES[:auth]) }
  scope :profile_activities, -> { for_category(CATEGORIES[:profile]) }
  scope :permission_activities, -> { for_category(CATEGORIES[:permissions]) }
  scope :security_activities, -> { for_category(CATEGORIES[:security]) }

  # Callbacks
  before_validation :set_defaults
  after_create_commit :notify_admins_if_security_event

  # Class Methods

  # Creates an activity with request context
  def self.track!(user, action, **options)
    request = options[:request]

    activity_params = {
      user: user,
      action: action,
      category: category_for_action(action),
      status: options[:status] || STATUSES[:success],
      metadata: options[:metadata] || {},
      attribute_changes: options[:changes] || {},
      trackable: options[:trackable],
      organisation: options[:organisation] || user.organisations.first,
      failure_reason: options[:failure_reason]
    }

    if request.present?
      activity_params.merge!(
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        session_id: request.session.id.to_s
      )
    end

    create!(activity_params)
  end

  # Helper for failed activities
  def self.track_failure!(user, action, reason, **options)
    track!(user, action, **options, status: STATUSES[:failed], failure_reason: reason)
  end

  # Determines the category based on the action
  def self.category_for_action(action)
    case action.to_s
    when 'login', 'logout', 'login_failed', 'registered',
         'password_reset_requested', 'password_reset_completed'
      CATEGORIES[:auth]
    when 'email_changed', 'profile_updated'
      CATEGORIES[:profile]
    when 'role_assigned', 'role_removed', 'permissions_changed',
         'project_access_granted', 'project_access_revoked'
      CATEGORIES[:permissions]
    when 'account_locked', 'account_unlocked', 'api_token_created',
         'api_token_deleted', 'suspicious_activity',
         'data_export_requested', 'data_export_downloaded'
      CATEGORIES[:security]
    when 'invitation_sent', 'invitation_accepted', 'invitation_declined'
      CATEGORIES[:invitations]
    else
      CATEGORIES[:auth] # Default
    end
  end

  # Instance Methods

  # Returns a readable description of the activity
  def description
    case action
    when ACTIONS[:login]
      I18n.t('models.user_activity.descriptions.login', location_info: location_info)
    when ACTIONS[:logout]
      I18n.t('models.user_activity.descriptions.logout')
    when ACTIONS[:login_failed]
      I18n.t('models.user_activity.descriptions.login_failed', location_info: location_info)
    when ACTIONS[:registered]
      I18n.t('models.user_activity.descriptions.registered')
    when ACTIONS[:password_reset_requested]
      I18n.t('models.user_activity.descriptions.password_reset_requested')
    when ACTIONS[:password_reset_completed]
      I18n.t('models.user_activity.descriptions.password_reset_completed')
    when ACTIONS[:email_changed]
      email_change_description
    when ACTIONS[:profile_updated]
      I18n.t('models.user_activity.descriptions.profile_updated')
    when ACTIONS[:role_assigned]
      role_change_description(I18n.t('models.user_activity.descriptions.role_action_assigned'))
    when ACTIONS[:role_removed]
      role_change_description(I18n.t('models.user_activity.descriptions.role_action_removed'))
    when ACTIONS[:permissions_changed]
      I18n.t('models.user_activity.descriptions.permissions_changed')
    when ACTIONS[:project_access_granted]
      project_access_description(I18n.t('models.user_activity.descriptions.project_action_granted'))
    when ACTIONS[:project_access_revoked]
      project_access_description(I18n.t('models.user_activity.descriptions.project_action_revoked'))
    when ACTIONS[:account_locked]
      I18n.t('models.user_activity.descriptions.account_locked', lock_reason: lock_reason)
    when ACTIONS[:account_unlocked]
      I18n.t('models.user_activity.descriptions.account_unlocked')
    when ACTIONS[:invitation_sent]
      invitation_description(I18n.t('models.user_activity.descriptions.invitation_action_sent'))
    when ACTIONS[:invitation_accepted]
      invitation_description(I18n.t('models.user_activity.descriptions.invitation_action_accepted'))
    when ACTIONS[:invitation_declined]
      invitation_description(I18n.t('models.user_activity.descriptions.invitation_action_declined'))
    when ACTIONS[:data_export_requested]
      I18n.t('models.user_activity.descriptions.data_export_requested')
    when ACTIONS[:data_export_downloaded]
      I18n.t('models.user_activity.descriptions.data_export_downloaded')
    else
      action.humanize
    end
  end

  # Icon for the activity
  def icon_class
    case category
    when CATEGORIES[:auth]
      'bi bi-shield-lock'
    when CATEGORIES[:profile]
      'bi bi-person-circle'
    when CATEGORIES[:permissions]
      'bi bi-key'
    when CATEGORIES[:security]
      'bi bi-exclamation-triangle'
    when CATEGORIES[:invitations]
      'bi bi-envelope'
    else
      'bi bi-activity'
    end
  end

  # CSS class based on status
  def status_class
    case status
    when STATUSES[:success]
      'text-green-600'
    when STATUSES[:failed]
      'text-red-600'
    when STATUSES[:pending]
      'text-yellow-600'
    else
      'text-gray-600'
    end
  end

  # Checks whether this is a security-relevant activity
  def security_relevant?
    category == CATEGORIES[:security] ||
      action.in?([ACTIONS[:login_failed], ACTIONS[:account_locked],
                  ACTIONS[:suspicious_activity]])
  end

  # Checks whether this is a critical activity
  def critical?
    action.in?([ACTIONS[:account_locked], ACTIONS[:suspicious_activity],
                ACTIONS[:permissions_changed], ACTIONS[:role_assigned]])
  end

  private

  def set_defaults
    self.status ||= STATUSES[:success]
    self.metadata ||= {}
    self.attribute_changes ||= {}
    self.category ||= self.class.category_for_action(action) if action.present?
  end

  def notify_admins_if_security_event
    # TODO: Implement admin notification for critical events
    # e.g. via ActionMailer or the notification system
    return unless critical? && status == STATUSES[:failed]

    Rails.logger.warn "[SECURITY] Critical activity detected: #{action} for user #{user.email}"
  end

  # Helper methods for descriptions

  def location_info
    return '' if ip_address.blank?

    I18n.t('models.user_activity.descriptions.location_info', ip: ip_address)
  end

  # Names no address: organisation admins read this log on the member's
  # activity page, and a member chooses which email the others see
  # (User::EmailDisplay).
  def email_change_description
    I18n.t('models.user_activity.descriptions.email_changed')
  end

  def role_change_description(action_text)
    if metadata['role_name'].present?
      I18n.t('models.user_activity.descriptions.role_changed',
             role_name: metadata['role_name'], action_text: action_text)
    else
      I18n.t('models.user_activity.descriptions.role_changed_no_name', action_text: action_text)
    end
  end

  def project_access_description(action_text)
    if metadata['project_name'].present?
      I18n.t('models.user_activity.descriptions.project_access',
             project_name: metadata['project_name'], action_text: action_text)
    else
      I18n.t('models.user_activity.descriptions.project_access_no_name', action_text: action_text)
    end
  end

  def lock_reason
    return '' if metadata['reason'].blank?

    I18n.t('models.user_activity.descriptions.lock_reason', reason: metadata['reason'])
  end

  def invitation_description(action_text)
    if metadata['invited_email'].present?
      I18n.t('models.user_activity.descriptions.invitation',
             email: metadata['invited_email'], action_text: action_text)
    else
      I18n.t('models.user_activity.descriptions.invitation_no_email', action_text: action_text)
    end
  end
end
