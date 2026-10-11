# frozen_string_literal: true

require 'rails_helper'

# Actors::AcceptTicketSuggestion — turns a meeting ticket suggestion into a real
# ticket (Gespräche Slice 8).
#
# Intent: prove the three invariants the endpoint leans on — the happy chain
# (SaveTicket → Meeting→Ticket reference → status accepted + created_ticket_id), the
# 3A atomic guard (a non-open suggestion yields a friendly failure and NO second
# ticket), and the rollback (a SaveTicket failure rolls the status flip back to open,
# leaving no ticket and no link behind).
RSpec.describe Actors::AcceptTicketSuggestion do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:current_user) do
    user = create(:user)
    role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, meetings_access: :read_write, tickets_access: :read_write)
    user
  end
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: current_user) }
  let(:suggestion) do
    create(:meeting_ticket_suggestion, meeting: meeting, title: 'Rechnung senden',
                                       description: 'An Kunde X das Angebot nachfassen.')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'happy path' do
    it 'creates a real ticket, links the meeting to it, and records the accept' do
      result = nil
      expect do
        result = described_class.call(meeting: meeting, suggestion: suggestion, current_user: current_user)
      end.to change(Ticket, :count).by(1)

      expect(result).to be_success
      ticket = result.resource
      expect(ticket.title).to eq('Rechnung senden')
      expect(ticket.number).to be_present # SaveTicket assigns the per-project number

      suggestion.reload
      expect(suggestion).to be_accepted
      expect(suggestion.created_ticket_id).to eq(ticket.id)

      # Meeting→Ticket reference exists (backlink infrastructure), title snapshotted.
      reference = meeting.outgoing_references.where(target_type: Ticket.polymorphic_name).first
      expect(reference.target_id).to eq(ticket.id)
      expect(reference.target_title_snapshot).to eq(ticket.display_title)
    end
  end

  describe '3A atomic guard (no second ticket)' do
    it 'fails with :already_processed when the suggestion is not open, creating no ticket' do
      suggestion.accepted!

      result = nil
      expect do
        result = described_class.call(meeting: meeting, suggestion: suggestion, current_user: current_user)
      end.not_to change(Ticket, :count)

      expect(result).not_to be_success
      expect(result.code).to eq(:already_processed)
    end
  end

  describe 'rollback on ticket-creation failure' do
    it 'rolls the status flip back to open and leaves no ticket or link behind' do
      failure = Actors::BaseActor::Result.new(success: false, errors: ['boom'], code: :validation_failed)
      allow(Actors::SaveTicket).to receive(:call).and_return(failure)

      result = nil
      expect do
        result = described_class.call(meeting: meeting, suggestion: suggestion, current_user: current_user)
      end.not_to change(Ticket, :count)

      expect(result).not_to be_success
      # The atomic claim (open → accepted) must be rolled back with the failed chain.
      expect(suggestion.reload).to be_open
      expect(suggestion.created_ticket_id).to be_nil
      expect(meeting.outgoing_references.count).to eq(0)
    end
  end
end
