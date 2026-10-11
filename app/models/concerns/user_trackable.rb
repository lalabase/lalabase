# frozen_string_literal: true

# Concern for user activity tracking
module UserTrackable
  extend ActiveSupport::Concern

  included do
    has_many :user_activities, dependent: :destroy

    # Callbacks for automatic tracking
    after_update :track_profile_changes
    after_update :track_email_change
  end

  # Public methods for manual tracking

  def track_activity(action, **options)
    UserActivity.track!(self, action, **options)
  end

  def track_failed_activity(action, reason, **options)
    UserActivity.track_failure!(self, action, reason, **options)
  end

  # Suspends the after_update trackers for the given block. Exists for the GDPR
  # erasure: anonymize! must not record the very address it is removing --
  # track_email_change would store the real old_email in
  # user_activities.metadata on the erased account.
  def without_activity_tracking
    @activity_tracking_suspended = true
    yield
  ensure
    @activity_tracking_suspended = false
  end

  # Authentication Tracking

  def track_login(request: nil, organisation: nil)
    track_activity(UserActivity::ACTIONS[:login],
                   request: request,
                   organisation: organisation,
                   metadata: {
                     login_method: 'standard',
                     browser: browser_info(request)
                   })
  end

  def track_logout(request: nil)
    track_activity(UserActivity::ACTIONS[:logout],
                   request: request,
                   metadata: {
                     logout_type: 'manual'
                   })
  end

  def track_failed_login(request: nil, reason: nil)
    track_failed_activity(
      UserActivity::ACTIONS[:login_failed],
      reason || 'Invalid credentials',
      request: request,
      metadata: {
        attempted_email: email,
        browser: browser_info(request)
      }
    )
  end

  # Registration & Password

  def track_registration(request: nil, organisation: nil)
    track_activity(UserActivity::ACTIONS[:registered],
                   request: request,
                   organisation: organisation,
                   metadata: {
                     registration_method: 'standard',
                     # `invited_by_org_id` is the canonical column marking an
                     # invitation-originated account; the previous `invitation_token`
                     # reference was undefined and raised on every registration.
                     invited: invited_by_org_id.present?
                   })
  end

  def track_password_reset_request(request: nil)
    track_activity(UserActivity::ACTIONS[:password_reset_requested],
                   request: request,
                   metadata: {
                     reset_method: 'email'
                   })
  end

  def track_password_reset_completion(request: nil)
    track_activity(UserActivity::ACTIONS[:password_reset_completed],
                   request: request)
  end

  # Account Security

  def track_account_lock(reason: nil)
    track_activity(UserActivity::ACTIONS[:account_locked],
                   metadata: {
                     reason: reason || 'Manual lock',
                     locked_at: Time.current
                   })
  end

  def track_account_unlock
    track_activity(UserActivity::ACTIONS[:account_unlocked],
                   metadata: {
                     unlocked_at: Time.current
                   })
  end

  # Permissions & Roles

  def track_role_assignment(role, project: nil, assigned_by: nil)
    track_activity(UserActivity::ACTIONS[:role_assigned],
                   trackable: project,
                   metadata: {
                     role_name: role.title,
                     role_id: role.id,
                     project_name: project&.name,
                     assigned_by_id: assigned_by&.id,
                     assigned_by_name: assigned_by&.full_name
                   })
  end

  def track_role_removal(role, project: nil, removed_by: nil)
    track_activity(UserActivity::ACTIONS[:role_removed],
                   trackable: project,
                   metadata: {
                     role_name: role.title,
                     role_id: role.id,
                     project_name: project&.name,
                     removed_by_id: removed_by&.id,
                     removed_by_name: removed_by&.full_name
                   })
  end

  def track_project_access_grant(project, granted_by: nil)
    track_activity(UserActivity::ACTIONS[:project_access_granted],
                   trackable: project,
                   metadata: {
                     project_name: project.name,
                     project_id: project.id,
                     granted_by_id: granted_by&.id,
                     granted_by_name: granted_by&.full_name
                   })
  end

  def track_project_access_revoke(project, revoked_by: nil)
    track_activity(UserActivity::ACTIONS[:project_access_revoked],
                   trackable: project,
                   metadata: {
                     project_name: project.name,
                     project_id: project.id,
                     revoked_by_id: revoked_by&.id,
                     revoked_by_name: revoked_by&.full_name
                   })
  end

  # Invitations

  def track_invitation_sent(invited_email, organisation: nil)
    track_activity(UserActivity::ACTIONS[:invitation_sent],
                   organisation: organisation,
                   metadata: {
                     invited_email: invited_email,
                     invitation_sent_at: Time.current
                   })
  end

  def track_invitation_accepted(organisation: nil)
    track_activity(UserActivity::ACTIONS[:invitation_accepted],
                   organisation: organisation,
                   metadata: {
                     accepted_at: Time.current
                   })
  end

  # Query Methods

  def recent_activities(limit: 10)
    user_activities.recent.limit(limit)
  end

  def activities_for_category(category)
    user_activities.for_category(category).recent
  end

  def login_activities
    user_activities.where(action: [
                            UserActivity::ACTIONS[:login],
                            UserActivity::ACTIONS[:logout],
                            UserActivity::ACTIONS[:login_failed]
                          ]).recent
  end

  def security_activities
    user_activities.security_activities.recent
  end

  def failed_activities
    user_activities.failed.recent
  end

  def last_login_activity
    user_activities.where(action: UserActivity::ACTIONS[:login])
                   .successful
                   .recent
                   .first
  end

  def last_login_at
    last_login_activity&.created_at
  end

  def last_login_ip
    last_login_activity&.ip_address
  end

  # Statistics

  def login_count(since: nil)
    scope = user_activities.where(action: UserActivity::ACTIONS[:login]).successful
    scope = scope.where('created_at >= ?', since) if since
    scope.count
  end

  def failed_login_count(since: 1.day.ago)
    user_activities.where(action: UserActivity::ACTIONS[:login_failed])
                   .where('created_at >= ?', since)
                   .count
  end

  def has_suspicious_activity?(threshold: 5, timeframe: 1.hour.ago)
    failed_login_count(since: timeframe) >= threshold
  end

  private

  # Callbacks

  def track_profile_changes
    return if @activity_tracking_suspended
    return unless saved_changes.except('updated_at', 'email', 'encrypted_password').any?

    profile_changes = saved_changes.slice('first_name', 'last_name', 'avatar', 'bio')
    return if profile_changes.empty?

    track_activity(UserActivity::ACTIONS[:profile_updated],
                   attribute_changes: profile_changes,
                   metadata: {
                     changed_fields: profile_changes.keys
                   })
  end

  def track_email_change
    return if @activity_tracking_suspended
    return unless saved_change_to_email?

    track_activity(UserActivity::ACTIONS[:email_changed],
                   attribute_changes: { email: saved_change_to_email },
                   metadata: {
                     old_email: saved_change_to_email[0],
                     new_email: saved_change_to_email[1]
                   })
  end

  # Helper Methods

  def browser_info(request)
    return nil unless request

    user_agent = request.user_agent
    return nil unless user_agent

    # Simple browser detection
    browser = case user_agent
              when /Chrome/
                'Chrome'
              when /Safari/
                'Safari'
              when /Firefox/
                'Firefox'
              when /Edge/
                'Edge'
              else
                'Unknown'
              end

    # OS detection
    os = case user_agent
         when /Windows/
           'Windows'
         when /Mac/
           'macOS'
         when /Linux/
           'Linux'
         when /Android/
           'Android'
         when /iPhone|iPad/
           'iOS'
         else
           'Unknown'
         end

    "#{browser} on #{os}"
  end
end
