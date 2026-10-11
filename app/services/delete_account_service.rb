# frozen_string_literal: true

class DeleteAccountService
  attr_reader :target_user, :requester, :source, :reason, :errors

  def initialize(target_user:, requester:, source:, reason: nil)
    @target_user = target_user
    @requester = requester
    @source = source
    @reason = reason
    @errors = []
  end

  def call
    return false unless valid?

    ActiveRecord::Base.transaction do
      grace_period_days = SystemSetting.account_deletion_grace_period_days

      if grace_period_days == 0 || source == 'backend'
        # Immediate deletion for backend or when grace period is 0
        perform_immediate_deletion
      else
        # Schedule deletion with grace period
        schedule_deletion_with_grace_period
      end

      true
    end
  rescue StandardError => e
    errors << e.message
    Rails.logger.error "Failed to process account deletion for #{target_user.id}: #{e.message}"
    false
  end

  private

  def valid?
    # Basic input validation first
    if target_user.nil?
      errors << 'Target user is required'
      return false
    end

    if requester.nil?
      errors << 'Requester is required'
      return false
    end

    if source.nil?
      errors << 'Source is required'
      return false
    end

    unless %w[selfservice backend].include?(source)
      errors << 'Invalid source: must be selfservice or backend'
      return false
    end

    if reason && reason.length > 500
      errors << 'Reason is too long (maximum 500 characters)'
      return false
    end

    unless target_user.can_be_deleted_by?(requester, source)
      errors << 'You do not have permission to delete this account'
      return false
    end

    if target_user.deleted?
      errors << 'User is already deleted'
      return false
    end

    # Self-service only: the instance admin (backend) may still delete anyone.
    if source == 'selfservice'
      orphaned = Memberships::LastAdminGuard.organisations_left_without_admin(target_user)
      if orphaned.any?
        orphaned.each { |org| errors << I18n.t('flash.memberships.last_active_admin', organisation: org.name) }
        return false
      end
    end

    true
  end

  def perform_immediate_deletion
    # Perform soft delete and anonymization
    target_user.soft_delete_and_anonymize!

    # Log the deletion
    UserDeletion.log_deletion(
      deleted_user: target_user,
      deleter: requester,
      source: source,
      reason: reason,
      executed_at: Time.current
    )

    # Broadcast deletion event
    broadcast_deletion_event('account.deleted')
  end

  def schedule_deletion_with_grace_period
    # Schedule the deletion
    target_user.schedule_deletion!(reason: reason)

    # Log the scheduled deletion
    UserDeletion.log_deletion(
      deleted_user: target_user,
      deleter: requester,
      source: source,
      reason: reason,
      scheduled_at: target_user.scheduled_deletion_at
    )

    # Broadcast scheduled deletion event
    broadcast_deletion_event('account.deletion_scheduled')

    # Track activity if available
    return unless target_user.respond_to?(:track_deletion_scheduled)

    target_user.track_deletion_scheduled(
      scheduled_for: target_user.scheduled_deletion_at,
      reason: reason
    )
  end

  def broadcast_deletion_event(event_name)
    # Broadcasting through ActiveSupport::Notifications
    ActiveSupport::Notifications.instrument(event_name, {
                                              user_id: target_user.id,
                                              deleter_id: requester.id,
                                              deleter_type: requester.class.name,
                                              source: source,
                                              deleted_at: Time.current,
                                              scheduled_for: target_user.scheduled_deletion_at
                                            })

    Rails.logger.info "Account deletion event: #{event_name} for User #{target_user.id} by #{requester.class.name} #{requester.id} via #{source}"
  end
end
