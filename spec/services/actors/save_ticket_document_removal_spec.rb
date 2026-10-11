# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SaveTicket, 'document removal' do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:user) do
    ActsAsTenant.current_tenant = organisation
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: create(:admin_role, organisation: organisation))
    u
  end

  let!(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, title: 'Test Ticket', creator: user)
  end

  let!(:ticket_document) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_document, ticket: ticket, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'removing ticket documents via remove_document_ids' do
    it 'destroys the ticket document when remove_document_ids is provided' do
      params = ActionController::Parameters.new(
        title: ticket.title,
        remove_document_ids: [ticket_document.id.to_s]
      ).permit!

      actor = described_class.new(project: project, params: params, id: ticket.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(TicketDocument.find_by(id: ticket_document.id)).to be_nil
    end

    it 'reloads the ticket_documents association after removal' do
      params = ActionController::Parameters.new(
        title: ticket.title,
        remove_document_ids: [ticket_document.id.to_s]
      ).permit!

      actor = described_class.new(project: project, params: params, id: ticket.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(result.resource.ticket_documents).to be_empty
    end

    it 'keeps the ticket document when remove_document_ids is empty' do
      params = ActionController::Parameters.new(
        title: ticket.title,
        remove_document_ids: []
      ).permit!

      actor = described_class.new(project: project, params: params, id: ticket.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(TicketDocument.find_by(id: ticket_document.id)).to be_present
    end

    it 'keeps the ticket document when remove_document_ids is not provided' do
      params = ActionController::Parameters.new(
        title: ticket.title
      ).permit!

      actor = described_class.new(project: project, params: params, id: ticket.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(TicketDocument.find_by(id: ticket_document.id)).to be_present
    end

    it 'returns resource in the Result even when update fails' do
      params = ActionController::Parameters.new(
        title: '', # blank title triggers validation error
        remove_document_ids: [ticket_document.id.to_s]
      ).permit!

      actor = described_class.new(project: project, params: params, id: ticket.id, current_user: user)
      result = actor.call

      expect(result).not_to be_success
      expect(result.resource).to be_present
      expect(result.resource).to eq(ticket)
      # Document should NOT be removed when update fails
      expect(TicketDocument.find_by(id: ticket_document.id)).to be_present
    end
  end
end
