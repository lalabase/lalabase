# frozen_string_literal: true

require 'rails_helper'

# A move to another project keeps a ticket's relations (doc/ticket_relations_plan.md,
# revision 4, §3.3). Relations may cross projects, and both ways of moving stay inside the
# organisation, so a move breaks no rule and cleans nothing up. Held for every path the plan
# names: the single move, the bulk move, a move that retries after a number conflict, and a
# move that fails and rolls back.
RSpec.describe 'Moving a ticket keeps its relations', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:source_project) { create(:project, organisation: organisation, name: 'Quelle') }
  let(:target_project) { create(:project, organisation: organisation, name: 'Ziel') }
  let(:elsewhere) { create(:project, organisation: organisation, name: 'Anderswo') }

  # Before the let! below: they need its tenant.
  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
  end

  let!(:ticket) { create(:ticket, project: source_project, creator: user, title: 'Moves') }
  let!(:blocker) { create(:ticket, project: elsewhere, creator: user, title: 'Blocks it') }
  let!(:follower) { create(:ticket, project: source_project, creator: user, title: 'Follows it') }
  let!(:incoming) { TicketRelation.create!(source_ticket: blocker, target_ticket: ticket, relation_type: :blocks) }
  let!(:outgoing) do
    TicketRelation.create!(source_ticket: ticket, target_ticket: follower, relation_type: :precedes, delay_days: 2)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Current.user = nil
  end

  # Relations cannot be reordered in place: ends and type are read-only. Same ids, same ends.
  def expect_relations_intact
    expect(TicketRelation.order(:created_at).pluck(:id, :source_ticket_id, :target_ticket_id, :relation_type, :delay_days))
      .to eq([[incoming.id, blocker.id, ticket.id, 'blocks', nil], [outgoing.id, ticket.id, follower.id, 'precedes', 2]])
    expect(Tickets::Waiting.for(ticket.reload).map(&:id)).to eq([blocker.id])
  end

  it 'survives the single move' do
    result = Actors::MoveTicket.call(ticket: ticket, target_project: target_project, current_user: user)

    expect(result).to be_success
    expect(ticket.reload.project_id).to eq(target_project.id)
    expect_relations_intact
  end

  it 'survives the bulk move' do
    other = create(:ticket, project: source_project, creator: user, title: 'Moves along')

    # The next number is read once per ticket: the bulk move is one move per ticket by design.
    result = Prosopite.pause do
      Actors::MoveTickets.call(project: source_project, ticket_ids: [ticket.id, other.id],
                               target_project: target_project, current_user: user)
    end

    expect(result).to be_success
    expect(ticket.reload.project_id).to eq(target_project.id)
    expect_relations_intact
  end

  it 'survives a move that retries after a number conflict' do
    attempts = 0
    allow(ticket).to receive(:update_columns).and_wrap_original do |original, *args|
      attempts += 1
      raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint' if attempts == 1

      original.call(*args)
    end

    # The retry reads the next number again, which is its point.
    result = Prosopite.pause { Actors::MoveTicket.call(ticket: ticket, target_project: target_project, current_user: user) }

    expect(result).to be_success
    expect(attempts).to eq(2)
    expect(ticket.reload.project_id).to eq(target_project.id)
    expect_relations_intact
  end

  it 'survives a move that fails and rolls back' do
    allow_any_instance_of(Project).to receive(:track_ticket_moved_out).and_raise(StandardError, 'boom')

    # Unexpected errors re-raise in dev/test (production logs them and answers a failure).
    expect { Actors::MoveTicket.call(ticket: ticket, target_project: target_project, current_user: user) }
      .to raise_error(StandardError, 'boom')

    expect(ticket.reload.project_id).to eq(source_project.id)
    expect_relations_intact
  end
end
