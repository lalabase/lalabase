# frozen_string_literal: true

class ScheduledDeletionJob < ApplicationJob
  queue_as :default

  def perform
    users_to_delete = User.where('scheduled_deletion_at <= ?', Time.current)
                          .where(deleted_at: nil)

    users_to_delete.find_each do |user|
      execute_scheduled_deletion(user)
    rescue StandardError => e
      Rails.logger.error "ScheduledDeletionJob: Failed to delete user #{user.id}: #{e.message}"
      Rails.logger.error e.backtrace&.first(5)&.join("\n")
    end
  end

  private

  def execute_scheduled_deletion(user)
    Rails.logger.info "ScheduledDeletionJob: Executing deletion for user #{user.id}"

    now = Time.current

    ActiveRecord::Base.transaction do
      user.soft_delete_and_anonymize!

      update_or_create_deletion_log(user, now)

      ActiveSupport::Notifications.instrument('account.deletion_executed', {
                                                user_id: user.id,
                                                scheduled_at: user.scheduled_deletion_at,
                                                executed_at: now
                                              })

      Rails.logger.info "ScheduledDeletionJob: Successfully deleted user #{user.id}"
    end
  end

  def update_or_create_deletion_log(user, executed_at)
    deletion_log = UserDeletion.find_by(
      deleted_user_id: user.id,
      executed_at: nil
    )

    if deletion_log
      deletion_log.update!(
        executed_at: executed_at,
        deleted_at: executed_at
      )
    else
      UserDeletion.log_deletion(
        deleted_user: user,
        deleter: user,
        source: 'selfservice',
        reason: user.deletion_reason,
        executed_at: executed_at
      )
    end
  end
end
