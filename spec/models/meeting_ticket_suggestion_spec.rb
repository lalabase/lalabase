# frozen_string_literal: true

require 'rails_helper'

# MeetingTicketSuggestion — the persisted AI ticket suggestion (Gespräche Slice 8).
#
# Intent: pin the invariants the run/accept logic leans on — the status enum
# (open default; open/accepted/dismissed scopes drive the replace-open-only run
# semantics), tenant isolation, the two optional ticket FKs (similarity hint +
# created-ticket audit, both NULLIFY so a ticket delete never cascades into the
# suggestion history), and the 255-char title cap that mirrors the parse step.
RSpec.describe MeetingTicketSuggestion do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'status enum' do
    it 'defaults to open' do
      expect(create(:meeting_ticket_suggestion, meeting: meeting)).to be_open
    end

    it 'exposes the three states as scopes (replace-open leans on this)' do
      open      = create(:meeting_ticket_suggestion, meeting: meeting)
      accepted  = create(:meeting_ticket_suggestion, :accepted, meeting: meeting)
      dismissed = create(:meeting_ticket_suggestion, :dismissed, meeting: meeting)

      expect(described_class.open).to contain_exactly(open)
      expect(described_class.accepted).to contain_exactly(accepted)
      expect(described_class.dismissed).to contain_exactly(dismissed)
    end
  end

  describe 'validations' do
    it 'requires a title' do
      expect(build(:meeting_ticket_suggestion, meeting: meeting, title: nil)).to be_invalid
    end

    it 'accepts a 255-char title but rejects 256 (n / n+1 boundary)' do
      expect(build(:meeting_ticket_suggestion, meeting: meeting, title: 'a' * 255)).to be_valid
      expect(build(:meeting_ticket_suggestion, meeting: meeting, title: 'a' * 256)).to be_invalid
    end
  end

  describe 'ticket references (both optional, NULLIFY)' do
    it 'allows a suggestion with neither similar nor created ticket' do
      suggestion = create(:meeting_ticket_suggestion, meeting: meeting)
      expect(suggestion.similar_ticket).to be_nil
      expect(suggestion.created_ticket).to be_nil
    end

    it 'nullifies similar_ticket_id when the matched ticket is deleted (DB FK)' do
      ticket = create(:ticket, project: project, organisation: organisation)
      suggestion = create(:meeting_ticket_suggestion, meeting: meeting, similar_ticket: ticket)

      ticket.destroy
      expect(suggestion.reload.similar_ticket_id).to be_nil
    end
  end

  describe 'tenant isolation (acts_as_tenant)' do
    it 'never reads another tenant’s suggestions' do
      create(:meeting_ticket_suggestion, meeting: meeting)

      other_org = create(:organisation)
      other_project = create(:project, organisation: other_org)
      ActsAsTenant.with_tenant(other_org) do
        other_meeting = create(:meeting, organisation: other_org, project: other_project)
        create(:meeting_ticket_suggestion, meeting: other_meeting, organisation: other_org)
        expect(described_class.count).to eq(1)
      end
      expect(described_class.count).to eq(1)
    end
  end

  describe 'meeting deletion' do
    it 'removes the suggestions but keeps the tickets they reference' do
      similar = create(:ticket, project: project, organisation: organisation)
      created = create(:ticket, project: project, organisation: organisation)
      create(:meeting_ticket_suggestion, meeting: meeting, similar_ticket: similar, created_ticket: created)

      expect { meeting.destroy }.to change(described_class, :count).by(-1)
      expect(Ticket.exists?(similar.id)).to be(true)
      expect(Ticket.exists?(created.id)).to be(true)
    end
  end
end
