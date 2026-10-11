# frozen_string_literal: true

require 'rails_helper'

# What: Actors::MoveTickets, the bulk move (doc/ticket_bulk_edit_plan.md, slice 7).
# Type: actor spec.
# Why: every ticket moves through Tickets::Mover with a new number in the
#   target; with several tickets the per-ticket activities (ticket, source,
#   target) are silent members of the run and the source project gets ONE line
#   that notifies while the target's line only tells its feed; a ticket with a
#   hierarchy is named and the others move; with one ticket the chain of today
#   holds and a refusal is the failure of the call. No undo.
RSpec.describe Actors::MoveTickets, :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:follower) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:target) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Ziel') } }

  before do
    bulk_project_setup
    bulk_member(follower)
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(ticket_ids, target_project: target)
    described_class.call(project: project, ticket_ids: ticket_ids, target_project: target_project, current_user: writer)
  end

  context 'with several tickets' do
    let!(:tickets) { [bulk_ticket(title: 'One'), bulk_ticket(title: 'Two')] }

    it 'moves every ticket with a new number, records the run, and writes one silent member row per activity and one line per project' do
      result = run(tickets.map(&:id))

      expect(result).to be_success
      run_record = result.resource
      expect(run_record).to have_attributes(kind: 'move', changed_count: 2, failed_count: 0, target_project_name: 'Ziel')
      expect(run_record.undoable?).to be(false)
      expect(tickets.map { |t| t.reload.project_id }).to all(eq(target.id))
      expect(tickets.map(&:number)).to match_array([1, 2])
      expect(run_record.results.values.map { |r| r['new_number'] }).to match_array([1, 2])

      moved = Activity.find_by(trackable: tickets.first, action: 'moved')
      expect(moved.parameters).to include('bulk_run_id' => run_record.id, 'bulk_run_member' => true, 'skip_notifications' => true)
      out = Activity.where(trackable: project, action: 'ticket_moved_out')
      expect(out.count).to eq(2)
      expect(out.first.parameters['bulk_run_member']).to be(true)
      expect(Activity.feed.where(id: out.select(:id))).not_to exist
      expect(Activity.where(trackable: target, action: 'ticket_moved_in').first.parameters['bulk_run_member']).to be(true)

      source_line = Activity.find_by(trackable: project, action: 'tickets_bulk_moved')
      expect(source_line.parameters).to include('count' => 2, 'target' => 'Ziel', 'bulk_run_id' => run_record.id)
      expect(source_line.parameters['skip_notifications']).to be_nil
      expect(OutboxEvent.where(activity_id: source_line.id)).to exist
      expect(Activity.feed.where(id: source_line.id)).to exist

      target_line = Activity.find_by(trackable: target, action: 'tickets_bulk_moved_in')
      expect(target_line.parameters).to include('count' => 2, 'source' => project.name, 'skip_notifications' => true)
      expect(OutboxEvent.where(activity_id: target_line.id)).not_to exist
    end

    it 'names a ticket with a sub-task and moves the others' do
      child = create(:ticket, project: project, organisation: organisation, creator: writer, parent: tickets.first, title: 'Child')

      result = run(tickets.map(&:id))

      expect(result).to be_success
      expect(result.resource).to have_attributes(changed_count: 1, failed_count: 1)
      expect(result.resource.failed_results.values.first).to include('error' => 'has_hierarchy', 'number' => tickets.first.number)
      expect(tickets.first.reload.project_id).to eq(project.id)
      expect(child.reload.project_id).to eq(project.id)
      expect(tickets.last.reload.project_id).to eq(target.id)
    end

    it 'refuses the same project, a stranger, and an empty set, and moves nothing' do
      expect(run(tickets.map(&:id), target_project: project).code).to eq(:target_project)
      foreign = create(:ticket, project: target, organisation: organisation, creator: writer)
      expect(run([tickets.first.id, foreign.id]).code).to eq(:outside_scope)
      expect(run([]).code).to eq(:empty)
      expect(TicketBulkRun.count).to eq(0)
      expect(tickets.map { |t| t.reload.project_id }).to all(eq(project.id))
    end
  end

  context 'with one ticket' do
    it 'keeps the chain of today, and a refusal is the failure of the call' do
      ticket = bulk_ticket
      result = run([ticket.id])

      expect(result).to be_success
      moved = Activity.find_by(trackable: ticket, action: 'moved')
      expect(moved.parameters['bulk_run_id']).to eq(result.resource.id)
      expect(moved.parameters['skip_notifications']).to be_nil
      expect(OutboxEvent.where(activity_id: moved.id)).to exist
      expect(Activity.where(trackable: project, action: 'tickets_bulk_moved')).not_to exist

      parent = bulk_ticket
      create(:ticket, project: project, organisation: organisation, creator: writer, parent: parent, title: 'Child')
      refused = run([parent.id])
      expect(refused).not_to be_success
      expect(refused.code).to eq(:has_hierarchy)
      expect(parent.reload.project_id).to eq(project.id)
      expect(TicketBulkRun.count).to eq(1)
    end
  end
end
