# frozen_string_literal: true

namespace :notifications do
  # A data backfill (Lalabase::DataBackfills::TASKS). Tickets::Mover moves a
  # ticket's notifications along since 2026-10-07; rows of tickets moved before
  # stayed in the old project, where the inbox rule (Notification.readable)
  # measured them against the wrong project's rights. Idempotent: an aligned row
  # is never touched again.
  desc "Move the notifications of moved tickets to their ticket's project (a data backfill)"
  task align_ticket_projects: :environment do
    aligned = ActsAsTenant.without_tenant do
      Notification.where(notifiable_type: 'Ticket')
                  .joins('INNER JOIN tickets ON tickets.id = notifications.notifiable_id')
                  .where('notifications.project_id IS DISTINCT FROM tickets.project_id')
                  .update_all('project_id = tickets.project_id')
    end
    puts "notifications:align_ticket_projects: #{aligned} notifications aligned."
  end
end
