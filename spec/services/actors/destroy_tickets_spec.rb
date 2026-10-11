# frozen_string_literal: true

require 'rails_helper'

# What: Actors::DestroyTickets, the bulk delete (doc/ticket_bulk_edit_plan.md, D15, slice 7).
# Type: actor spec.
# Why: every ticket goes through the model (its dependents with it, its
#   "deleted" activity stays as a silent member of the run), the project gets
#   ONE line that carries the followers read before the delete, because the
#   tickets take their subscriptions with them; with one ticket the chain of
#   today holds. No undo.
RSpec.describe Actors::DestroyTickets, :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:follower) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    bulk_project_setup
    bulk_member(follower)
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(ticket_ids)
    described_class.call(project: project, ticket_ids: ticket_ids, current_user: writer)
  end

  context 'with several tickets' do
    let!(:tickets) { [bulk_ticket(title: 'Alpha'), bulk_ticket(title: 'Beta')] }

    it 'deletes every ticket with its dependents, records the run, keeps a silent deleted row per ticket, and one line with the followers' do
      NotificationSubscription.system_subscribe(user: follower, item: tickets.first)
      create(:post, ticket: tickets.first, user: writer, organisation: organisation)
      numbers = tickets.map(&:number)

      result = run(tickets.map(&:id))

      expect(result).to be_success
      run_record = result.resource
      expect(run_record).to have_attributes(kind: 'delete', changed_count: 2, failed_count: 0)
      expect(run_record.results.values.map { |r| r['title'] }).to match_array(%w[Alpha Beta])
      expect(run_record.undoable?).to be(false)
      expect(Ticket.where(id: tickets.map(&:id))).not_to exist
      expect(Post.where(ticket_id: tickets.map(&:id))).not_to exist

      deleted = Activity.find_by(trackable_type: 'Ticket', trackable_id: tickets.first.id, action: 'deleted')
      expect(deleted.parameters).to include('bulk_run_id' => run_record.id, 'bulk_run_member' => true, 'skip_notifications' => true)
      expect(Activity.feed.where(id: deleted.id)).not_to exist

      line = Activity.find_by(trackable: project, action: 'tickets_bulk_deleted')
      expect(line.parameters).to include('count' => 2)
      # The creator is auto-subscribed too; the fanout drops the actor.
      expect(line.parameters['follower_ids']).to include(follower.id)
      expect(line.parameters['numbers']).to eq(numbers.sort.map { |n| "##{n}" }.join(', '))
      expect(OutboxEvent.where(activity_id: line.id)).to exist
    end

    it 'refuses a stranger and an empty set, and deletes nothing' do
      foreign = create(:ticket, project: create(:project, organisation: organisation), organisation: organisation, creator: writer)
      expect(run([tickets.first.id, foreign.id]).code).to eq(:outside_scope)
      expect(run([]).code).to eq(:empty)
      expect(TicketBulkRun.count).to eq(0)
      expect(Ticket.where(id: tickets.map(&:id)).count).to eq(2)
    end
  end

  context 'with one ticket' do
    it 'keeps the chain of today: the deleted activity notifies, no run line' do
      ticket = bulk_ticket
      result = run([ticket.id])

      expect(result).to be_success
      expect(Ticket.exists?(ticket.id)).to be(false)
      deleted = Activity.find_by(trackable_type: 'Ticket', trackable_id: ticket.id, action: 'deleted')
      expect(deleted.parameters['bulk_run_id']).to eq(result.resource.id)
      expect(deleted.parameters['skip_notifications']).to be_nil
      expect(Activity.where(trackable: project, action: 'tickets_bulk_deleted')).not_to exist
    end
  end
end
