# frozen_string_literal: true

namespace :notifications do
  # A data backfill (Lalabase::DataBackfills::TASKS). Until 2026-10-08
  # ProjectDeletionJob kept a deleted project's notifications with an empty
  # project_id, and a row without a project passes the inbox rule as a system
  # message (Notification.readable): what an area right had hidden came back. The
  # job deletes them now; this deletes the ones it left. A leftover has no project,
  # a project-bound subject, and that subject is gone. Kept, as in the job: a row
  # with a mail log (a later bounce finds its person through it; no inbox shows an
  # e-mail row). A row whose subject still lives is not touched, and neither is a
  # deleted ticket's row in a live project. NOT EXISTS rather than NOT IN: it runs
  # on every deploy and every container start. Idempotent.
  desc 'Delete the notifications deleted projects left behind (a data backfill)'
  task purge_project_leftovers: :environment do
    # The subjects that always live in a project: their own project_id is NOT NULL,
    # or they hang on a meeting or a ticket that has one. A notification about one
    # of them without a project can only be the leftover of a deleted project.
    project_bound = %w[Ticket Note Document Project ProjectRepository Meeting MeetingAnalysis Post TimeSession]
    notifications = Notification.arel_table
    mailed = EmailLog.unscoped.where(EmailLog.arel_table[:notification_id].eq(notifications[:id])).arel.exists

    purged = ActsAsTenant.without_tenant do
      project_bound.sum do |type|
        subject = type.constantize
        alive = subject.unscoped.where(subject.arel_table[:id].eq(notifications[:notifiable_id])).arel.exists
        Notification.where(project_id: nil, notifiable_type: type).where.not(alive).where.not(mailed).delete_all
      end
    end
    puts "notifications:purge_project_leftovers: #{purged} notifications deleted."
  end
end
