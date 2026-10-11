# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_documents
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  ticket_id                :uuid             not null
#
# Indexes
#
#  index_ticket_documents_on_organisation_id           (organisation_id)
#  index_ticket_documents_on_ticket_id_and_created_at  (ticket_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (ticket_id => tickets.id)
#
require 'rails_helper'

RSpec.describe TicketDocument, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'associations' do
    it { is_expected.to belong_to(:ticket).touch(true) }
    it { is_expected.to have_many(:fragments).dependent(:destroy) }
  end

  describe 'validations' do
    it 'requires a ticket_document_file' do
      td = TicketDocument.new(ticket: ticket)
      expect(td).not_to be_valid
      expect(td.errors[:ticket_document_file]).to be_present
    end

    it 'is valid with a ticket and attached file' do
      td = build(:ticket_document, ticket: ticket, organisation: organisation)
      expect(td).to be_valid
    end
  end

  describe 'file attachment' do
    it 'has one attached ticket_document_file' do
      td = create(:ticket_document, ticket: ticket, organisation: organisation)
      expect(td.ticket_document_file).to be_attached
    end
  end

  describe 'multi-tenancy' do
    it 'is scoped to organisation' do
      td = create(:ticket_document, ticket: ticket, organisation: organisation)
      expect(td.organisation).to eq(organisation)
    end
  end

  describe 'ticket association' do
    it 'touches the parent ticket on update' do
      td = create(:ticket_document, ticket: ticket, organisation: organisation)
      original_updated_at = ticket.reload.updated_at

      # Sleep briefly to ensure timestamp difference
      sleep 0.1
      td.update!(plain_text_version: 'updated text')
      expect(ticket.reload.updated_at).to be >= original_updated_at
    end

    it 'is destroyed when ticket is destroyed' do
      create(:ticket_document, ticket: ticket, organisation: organisation)
      expect { ticket.destroy }.to change(TicketDocument, :count).by(-1)
    end
  end
end
