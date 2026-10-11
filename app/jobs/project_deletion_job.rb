# frozen_string_literal: true

class ProjectDeletionJob < ApplicationJob
  queue_as :default

  # no_touching has to wrap the OUTERMOST transaction, not just the destroy, because the
  # touch that breaks project deletion is a DEFERRED one. ActionText::RichText declares
  # `belongs_to :record, touch: true`, so destroying a note's rich text registers a
  # touch_later on the note; that touch is flushed in before_commit, by which point the
  # note row is gone. Notes carry lock_version (optimistic locking for concurrent wiki
  # edits), so the zero-row UPDATE is not a silent no-op but a StaleObjectError — it
  # aborted the deletion of every project that had at least one note.
  # Suppressing touches while deleting a subtree costs nothing: every record whose
  # updated_at would be bumped is being deleted in the same breath.
  def perform(project_id, organisation_id, _user_id)
    ActiveRecord::Base.no_touching { delete_project_with_dependents(project_id, organisation_id) }
  rescue StandardError => e
    Rails.logger.error "ProjectDeletionJob failed for project #{project_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  private

  def delete_project_with_dependents(project_id, organisation_id)
    organisation = Organisation.find(organisation_id)

    ActsAsTenant.with_tenant(organisation) do
      project = Project.find_by(id: project_id)
      return unless project&.archived?

      ActiveRecord::Base.transaction do
        # 1. Collect IDs BEFORE dependent:destroy deletes them
        ticket_ids = project.tickets.pluck(:id)
        time_session_ids = project.time_sessions.pluck(:id)
        smart_folder_ids = project.smart_folders.pluck(:id)
        note_ids = project.notes.pluck(:id)
        document_ids = project.documents.pluck(:id)
        # No chat_ids: since projekt_chat_abbau no chat belongs to a project, so a
        # project deletion can orphan no chat Activity. The line that collected them
        # went with Project#has_many :chats.
        view_config_ids = project.view_configurations.pluck(:id)

        all_trackable_pairs = [
          ['Project', [project_id]],
          ['Ticket', ticket_ids],
          ['TimeSession', time_session_ids],
          ['SmartFolder', smart_folder_ids],
          ['Note', note_ids],
          ['Document', document_ids],
          ['ViewConfiguration', view_config_ids]
        ].select { |_, ids| ids.any? }

        # 2. Combined Activity scope for all trackable pairs (avoids N+1)
        all_activities_scope = all_trackable_pairs
                               .map { |type, ids| Activity.where(trackable_type: type, trackable_id: ids) }
                               .reduce(:or)

        # 3. Delete OutboxEvents for affected activities (FK: outbox_events → activities)
        activity_ids = all_activities_scope.pluck(:id)
        OutboxEvent.where(activity_id: activity_ids).delete_all if activity_ids.any?

        # 4. Delete activities (now without FK conflict)
        all_activities_scope.delete_all

        # 5. Delete NotificationSubscriptions (polymorphic)
        NotificationSubscription.where(subscribable: project).delete_all
        if ticket_ids.any?
          NotificationSubscription.where(
            subscribable_type: 'Ticket', subscribable_id: ticket_ids
          ).delete_all
        end

        # 6. Delete NotificationPreferences for project scope
        NotificationPreference.where(scope_type: 'Project', scope_id: project_id).delete_all

        # 7. Delete the project's notifications. Until 2026-10-08 they stayed with an
        # empty project_id, and a row without a project passes the inbox rule as a
        # system message: what an area right had hidden came back with its payload.
        # Kept: a row with a mail log (only an e-mail row gets one, and no inbox shows
        # e-mail rows). The log is how a later bounce or spam complaint finds its
        # person (EmailWebhookProcessorJob, EmailLog#check_and_disable_notifications),
        # and email_logs.notification_id cannot be empty. It loses only its project
        # (FK). The rows are locked first: a mail log written between the two
        # statements would otherwise fail the delete and roll the whole deletion back.
        project_notifications = Notification.where(project_id: project_id)
        project_notifications.lock.pluck(:id)
        mailed = EmailLog.unscoped.where(EmailLog.arel_table[:notification_id].eq(Notification.arel_table[:id]))
        project_notifications.where.not(mailed.arel.exists).delete_all
        project_notifications.update_all(project_id: nil)

        # 8. Delete CodebaseImportMappings
        CodebaseImportMapping.where(entity_type: 'Ticket', local_id: ticket_ids).delete_all if ticket_ids.any?

        # 9. Delete project (cascading via dependent: :destroy)
        project.destroy!
      end
    end
  end
end
