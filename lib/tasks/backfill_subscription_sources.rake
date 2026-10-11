# frozen_string_literal: true

namespace :subscriptions do
  desc 'Backfill source column for existing notification_subscriptions'
  task backfill_sources: :environment do
    batch_size = 500
    updated = 0

    NotificationSubscription
      .where(source: nil)
      .where(subscribable_type: 'Ticket')
      .includes(:user, subscribable: [:ticket_assignments])
      .find_each(batch_size: batch_size) do |sub|
        ticket = sub.subscribable
        next unless ticket

        source = if ticket.creator_id == sub.user_id
                   NotificationSubscription::SOURCE_CREATOR
                 elsif ticket.ticket_assignments.any? { |ta| ta.user_id == sub.user_id }
                   NotificationSubscription::SOURCE_ASSIGNEE
                 else
                   NotificationSubscription::SOURCE_SELF
                 end

        sub.update_column(:source, source)
        updated += 1
        print '.' if (updated % 100).zero?
      end

    puts "\nBackfilled #{updated} subscription sources."
  end
end
