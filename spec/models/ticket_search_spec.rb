# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket search without content column', type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'Ticket model' do
    it 'does not have a content column' do
      columns = Ticket.column_names
      expect(columns).not_to include('content')
    end

    it 'uses ActionText for content' do
      ticket = create(:ticket, project: project, organisation: organisation)
      expect(ticket).to respond_to(:content)
      expect(ticket.content).to be_a(ActionText::RichText)
    end
  end

  describe 'Search functionality' do
    let!(:ticket1) { create(:ticket, title: 'Änderungen PDF-Ausgabe', project: project, organisation: organisation) }
    let!(:ticket2) { create(:ticket, title: 'Bug in Login', project: project, organisation: organisation) }

    it 'can search by title without error' do
      # This was the failing query
      expect do
        Ticket.where(organisation_id: organisation.id)
              .where(project_id: project.id)
              .where('LOWER(tickets.title) ILIKE LOWER(?)', '%Änderungen PDF-Ausgabe%')
              .to_a
      end.not_to raise_error
    end

    it 'finds tickets by title search' do
      results = Ticket.where(organisation_id: organisation.id)
                      .where(project_id: project.id)
                      .where('LOWER(tickets.title) ILIKE LOWER(?)', '%PDF%')

      expect(results).to include(ticket1)
      expect(results).not_to include(ticket2)
    end

    it 'raises error when trying to search in content column' do
      # This demonstrates the original problem
      expect do
        Ticket.where(organisation_id: organisation.id)
              .where(project_id: project.id)
              .where('LOWER(tickets.title) ILIKE LOWER(?) OR LOWER(tickets.content) ILIKE LOWER(?)',
                     '%Änderungen PDF-Ausgabe%', '%Änderungen PDF-Ausgabe%')
              .to_a
      end.to raise_error(ActiveRecord::StatementInvalid, /column tickets.content does not exist/)
    end
  end

  describe 'Controller search configuration' do
    it 'TicketsController is configured to search only in title' do
      # This verifies the fix
      expect(Organisations::TicketsController.searchable_columns).to eq([:title])
      expect(Organisations::TicketsController.searchable_columns).not_to include(:content)
    end
  end

  describe 'ActionText content search' do
    let(:ticket) { create(:ticket, title: 'Test Ticket', project: project, organisation: organisation) }

    before do
      ticket.content.body = '<p>This contains PDF information</p>'
      ticket.save!
    end

    it 'can access content through ActionText association' do
      expect(ticket.content.to_plain_text).to include('PDF information')
    end

    it 'requires joins to search in ActionText content' do
      # Correct way to search in ActionText content
      results = Ticket.joins("INNER JOIN action_text_rich_texts ON action_text_rich_texts.record_id = tickets.id AND action_text_rich_texts.record_type = 'Ticket' AND action_text_rich_texts.name = 'content'")
                      .where('action_text_rich_texts.body ILIKE ?', '%PDF%')

      expect(results).to include(ticket)
    end
  end
end
