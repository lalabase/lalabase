# frozen_string_literal: true

require 'rails_helper'

# What: Actors::ApplyTicketChanges, the one actor for one ticket and for many
#   (doc/ticket_bulk_edit_plan.md, D13, D4, D11).
# Type: actor spec.
# Why: with one ticket the chain notifies as today; with several, every ticket's
#   activity carries the run id and skips notifications and broadcasts, and ONE
#   run activity on the project is the event. A ticket that cannot take the
#   change is named and the others commit. A changed stock refuses before
#   anything is written. The previous values land in the run for the undo.
RSpec.describe Actors::ApplyTicketChanges, :bulk_edit do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:follower) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    bulk_project_setup
    bulk_member(follower)
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(ticket_ids, changes, **extra)
    described_class.call(project: project, ticket_ids: ticket_ids, changes: changes, current_user: writer, **extra)
  end

  it 'refuses a new tag name over the limit with its code and the limit in words, and writes nothing' do
    tickets = [bulk_ticket, bulk_ticket]
    result = run(tickets.map(&:id), [{ 'field' => 'tags', 'add' => ['x' * (Tag::MAX_NAME_LENGTH + 1)] }])

    expect(result).not_to be_success
    expect(result.code).to eq(:tag_name_invalid)
    expect(Array(result.errors).join).to include(Tag::MAX_NAME_LENGTH.to_s)
    expect(TicketBulkRun.count).to eq(0)
  end

  # A deactivated member is no longer offered, but still removable
  # (BulkFields::Field#removable), and the run's sentence names them, not their id.
  it 'removes a deactivated assignee from several tickets and names them in the run' do
    gone = create(:user, first_name: 'Gerda', last_name: 'Gegangen')
    bulk_member(gone).update!(active: false)
    tickets = [bulk_ticket, bulk_ticket].each { |ticket| ticket.ticket_assignments.create!(user: gone) }

    result = run(tickets.map(&:id), [{ 'field' => 'assignees', 'remove' => [gone.id] }])

    expect(result).to be_success
    expect(tickets.map { |ticket| ticket.reload.assignees.to_a }).to all(be_empty)
    changes = Activity.find_by(trackable: project, action: 'tickets_bulk_changed').parameters['changes']
    expect(changes.to_s).to include('Gerda')
    expect(changes.to_s).not_to include(gone.id)
  end

  # A watcher subscription the actor made by hand stays removable once its
  # person is deactivated (BulkFields::Field#removable on watchers too).
  it 'removes a deactivated watcher' do
    gone = create(:user)
    membership = bulk_member(gone)
    ticket = bulk_ticket
    Current.set(user: writer) { NotificationSubscription.subscribe_other(user: gone, item: ticket, subscribed_by: writer) }
    membership.update!(active: false)

    result = run([ticket.id], [{ 'field' => 'watchers', 'remove' => [gone.id] }])

    expect(result).to be_success
    expect(NotificationSubscription.where(subscribable: ticket, user: gone)).not_to exist
  end

  # A watcher whose membership was deleted and who was never assigned: the
  # subscription alone makes them removable.
  it 'removes a watcher whose membership was deleted' do
    gone = create(:user)
    membership = bulk_member(gone)
    ticket = bulk_ticket
    Current.set(user: writer) { NotificationSubscription.subscribe_other(user: gone, item: ticket, subscribed_by: writer) }
    membership.destroy!

    result = run([ticket.id], [{ 'field' => 'watchers', 'remove' => [gone.id] }])

    expect(result).to be_success
    expect(NotificationSubscription.where(subscribable: ticket, user: gone)).not_to exist
  end

  # Who may be removed is asked only when a change removes somebody outside
  # the offered people, and only of the tickets in the change: a board drag of
  # the status reads neither assignments nor subscriptions for it (it cost
  # 115 ms per drag on a large instance when it read the whole project).
  it 'reads who may be removed only for a removal, and only of the tickets in the change' do
    ticket = bulk_ticket
    statements = []
    collect = ->(*, payload) { statements << payload[:sql] }
    removable_sql = ->(sql) { sql.include?('SELECT DISTINCT "ticket_assignments"."user_id"') }

    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
      Tickets::BulkFields.for(project: project, user: writer, ticket_ids: [ticket.id])
    end
    expect(statements.grep(/ticket_assignments|notification_subscriptions/)).to be_empty

    gone = create(:user)
    bulk_member(gone).destroy!
    ticket.ticket_assignments.create!(user: gone)
    statements.clear
    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
      expect(run([ticket.id], [{ 'field' => 'assignees', 'remove' => [gone.id] }])).to be_success
    end
    lookup = statements.find(&removable_sql)
    expect(lookup).to be_present
    # Filtered to the tickets of the change, not the whole project.
    expect(lookup).to match(/WHERE .*"tickets"\."id" (=|IN)/)
  end

  context 'with several tickets' do
    let!(:tickets) { [bulk_ticket, bulk_ticket, bulk_ticket({ 'status' => 'wip' })] }

    it 'writes every ticket, records the run with the previous values, and counts' do
      result = run(tickets.map(&:id), [{ 'field' => 'status', 'value' => 'wip' }])

      expect(result).to be_success
      expect(tickets.map { |t| t.reload.custom_attributes['status'] }).to all(eq('wip'))
      bulk_run = result.resource
      expect(bulk_run).to be_a(TicketBulkRun)
      expect(bulk_run.changed_count).to eq(3)
      expect(bulk_run.failed_count).to eq(0)
      expect(bulk_run.before_for(tickets.first.id)).to eq({ 'status' => 'open' })
      expect(bulk_run.before_for(tickets.last.id)).to eq({ 'status' => 'wip' })
      expect(bulk_run.change_list).to eq([{ 'field' => 'status', 'kind' => 'single', 'value' => 'wip' }])
    end

    it 'gives every ticket its own activity with the run id and no notification, and the project ONE run activity' do
      expect do
        run(tickets.map(&:id), [{ 'field' => 'status', 'value' => 'wip' }])
      end.to change { Activity.where(trackable_type: 'Ticket', action: 'status_changed').count }.by(2)

      bulk_run = TicketBulkRun.last
      ticket_activities = Activity.where(trackable_type: 'Ticket').where("parameters->>'bulk_run_id' = ?", bulk_run.id)
      expect(ticket_activities.count).to eq(2)
      expect(ticket_activities.map { |a| a.parameters['skip_notifications'] }).to all(be(true))
      expect(OutboxEvent.where(activity_id: ticket_activities.select(:id))).not_to exist

      project_activity = Activity.find_by(trackable: project, action: 'tickets_bulk_changed')
      expect(project_activity).to be_present
      expect(project_activity.key).to eq('project.tickets_bulk_changed')
      expect(project_activity.parameters['bulk_run_id']).to eq(bulk_run.id)
      expect(project_activity.parameters['count']).to eq(3)
      expect(project_activity.parameters['ticket_ids']).to match_array(tickets.map(&:id))
      expect(project_activity.parameters['changes']).to include('in Arbeit')
      expect(OutboxEvent.where(activity_id: project_activity.id)).to exist
    end

    it 'names a ticket that cannot take the change and commits the others' do
      # A ticket that cannot be saved (its title was emptied behind the
      # validations' back) fails on its own savepoint; the others go through.
      unlucky = bulk_ticket(title: 'unlucky')
      unlucky.update_column(:title, '')

      result = run([tickets.first.id, unlucky.id], [{ 'field' => 'status', 'value' => 'wip' }])

      expect(result).to be_success
      expect(result.resource.changed_count).to eq(1)
      expect(result.resource.failed_count).to eq(1)
      expect(result.resource.failed_results.values.first).to include('error' => 'invalid', 'number' => unlucky.number)
      expect(tickets.first.reload.custom_attributes['status']).to eq('wip')
      expect(unlucky.reload.custom_attributes['status']).to eq('open')
      expect(Activity.find_by(trackable: project, action: 'tickets_bulk_changed').parameters['failed']).to eq(1)
    end

    it 'refuses when the stock the reader saw is not the stock under the lock, and writes nothing' do
      stale = Tickets::BulkSummary.call(project: project, ticket_ids: tickets.map(&:id),
                                        fields: Tickets::BulkFields.for(project: project, user: writer))
      tickets.first.update!(custom_attributes: { 'status' => 'wip' })

      result = run(tickets.map(&:id), [{ 'field' => 'status', 'value' => 'open' }],
                   expected_stock: { 'status' => stale[:fields]['status'][:digest] })

      expect(result).not_to be_success
      expect(result.code).to eq(:stock_changed)
      expect(TicketBulkRun.count).to eq(0)
      expect(tickets.last.reload.custom_attributes['status']).to eq('wip')

      fresh = Tickets::BulkSummary.call(project: project, ticket_ids: tickets.map(&:id),
                                        fields: Tickets::BulkFields.for(project: project, user: writer))
      expect(run(tickets.map(&:id), [{ 'field' => 'status', 'value' => 'open' }],
                 expected_stock: { 'status' => fresh[:fields]['status'][:digest] })).to be_success
    end

    it 'refuses an empty set, a stranger, and a change the catalogue does not know' do
      expect(run([], [{ 'field' => 'status', 'value' => 'wip' }]).code).to eq(:empty)
      foreign = create(:ticket, project: create(:project, organisation: organisation), organisation: organisation, creator: writer)
      expect(run([tickets.first.id, foreign.id], [{ 'field' => 'status', 'value' => 'wip' }]).code).to eq(:outside_scope)
      expect(run(tickets.map(&:id), []).code).to eq(:no_changes)
      expect(run(tickets.map(&:id), [{ 'field' => 'status', 'value' => 'nope' }]).code).to eq(:value_not_allowed)
      expect(TicketBulkRun.count).to eq(0)
    end
  end

  context 'with one ticket' do
    let!(:ticket) { bulk_ticket }

    it 'keeps the chain of today: the activity notifies, the feed shows it, the run is still recorded' do
      result = run([ticket.id], [{ 'field' => 'status', 'value' => 'wip' }])

      expect(result).to be_success
      activity = Activity.find_by(trackable: ticket, action: 'status_changed')
      expect(activity.parameters['bulk_run_id']).to eq(result.resource.id)
      expect(activity.parameters['skip_notifications']).to be_nil
      expect(OutboxEvent.where(activity_id: activity.id)).to exist
      expect(Activity.where(trackable: project, action: 'tickets_bulk_changed')).not_to exist
      expect(Activity.feed.where(id: activity.id)).to exist
    end

    it 'answers with the run, sets the updater, and clears the field for the board drop into the unset column' do
      result = run([ticket.id], [{ 'field' => 'status', 'value' => 'wip' }])

      expect(result.resource).to be_a(TicketBulkRun)
      expect(ticket.reload.updater).to eq(writer)
      expect(run([ticket.id], [{ 'field' => 'status', 'clear' => true }])).to be_success
      expect(ticket.reload.custom_attributes['status']).to be_nil
    end

    it 'refuses a retired field and a value outside the options, and keeps the stored value' do
      expect(run([ticket.id], [{ 'field' => 'status', 'value' => 'nope' }]).code).to eq(:value_not_allowed)
      project.ticket_attribute_definitions.find_by(name: 'status').update!(active: false)
      expect(run([ticket.id], [{ 'field' => 'status', 'value' => 'wip' }]).code).to eq(:unknown_field)
      expect(ticket.reload.custom_attributes['status']).to eq('open')
    end

    it 'writes the field although a neighbour carries a value the project no longer allows' do
      ticket.update_column(:custom_attributes, ticket.custom_attributes.merge('due_date' => 'LEGACY_BOGUS'))

      expect(run([ticket.id], [{ 'field' => 'status', 'value' => 'wip' }])).to be_success
      expect(ticket.reload.custom_attributes).to include('status' => 'wip', 'due_date' => 'LEGACY_BOGUS')
    end

    it 'fails as a whole when its one ticket cannot be saved, and keeps no run' do
      ticket.update_column(:title, '')
      result = run([ticket.id], [{ 'field' => 'status', 'value' => 'wip' }])

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(TicketBulkRun.count).to eq(0)
      expect(ticket.reload.custom_attributes['status']).to eq('open')
    end
  end
end
