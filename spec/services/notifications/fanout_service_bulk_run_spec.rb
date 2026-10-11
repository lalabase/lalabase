# frozen_string_literal: true

require 'rails_helper'

# What: the fanout's recipient rule for a bulk run (doc/ticket_bulk_edit_plan.md, D4).
# Type: service spec through the outbox, as in production.
# Why: the run's activity on the project is the one event; its recipients are
#   the followers of the changed tickets, not the actor, not somebody without
#   access; and the tickets' own activities of the run reach nobody.
RSpec.describe 'Notifications::FanoutService for a bulk run', :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:follower) { create(:user) }
  let(:bystander) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    bulk_project_setup
    bulk_member(follower)
    bulk_member(bystander)
  end
  after { ActsAsTenant.current_tenant = nil }

  it 'notifies the followers of the changed tickets once per run and nobody else' do
    tickets = [bulk_ticket, bulk_ticket]
    NotificationSubscription.system_subscribe(user: follower, item: tickets.first)
    NotificationSubscription.system_subscribe(user: writer, item: tickets.last)

    Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                    changes: [{ 'field' => 'status', 'value' => 'wip' }])
    OutboxEvent.where(processed_at: nil).find_each(&:process!)

    run_notifications = Notification.where(event_type: 'tickets_bulk_changed')
    expect(run_notifications.pluck(:recipient_id).uniq).to eq([follower.id])
    expect(run_notifications.where(channel: 'in_app').count).to eq(1)
    expect(Notification.where(event_type: 'ticket_status_changed')).not_to exist
    expect(Notification.where(recipient: bystander)).not_to exist
  end

  it 'notifies the followers of deleted tickets from the run line, although their subscriptions went with the tickets' do
    tickets = [bulk_ticket, bulk_ticket]
    NotificationSubscription.system_subscribe(user: follower, item: tickets.first)

    Actors::DestroyTickets.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer)
    expect(NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: tickets.map(&:id))).not_to exist
    OutboxEvent.where(processed_at: nil).find_each(&:process!)

    run_notifications = Notification.where(event_type: 'tickets_bulk_deleted')
    expect(run_notifications.pluck(:recipient_id).uniq).to eq([follower.id])
    expect(Notification.where(recipient: bystander)).not_to exist
  end
end
