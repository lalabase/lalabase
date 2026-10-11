# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket content search', type: :model do
  let(:org) { create(:organisation) }
  let(:project) { create(:project, organisation: org) }

  before do
    ActsAsTenant.current_tenant = org
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'searching in ticket content' do
    it 'raises error when trying to search in non-existent tickets.content column' do
      # This reproduces the exact SQL error from the bug report
      create(:ticket, project: project, title: 'Test ticket')

      query = Ticket.where(project: project)

      # This is what the TextFilter would try to do with the wrong field mapping
      expect do
        query.where('tickets.content ILIKE ?', '%content%').to_a
      end.to raise_error(ActiveRecord::StatementInvalid, /column tickets.content does not exist/)
    end

    it 'works correctly when searching with ActionText join' do
      ticket = create(:ticket, project: project, title: 'Test ticket')
      ticket.content = 'Some content here'
      ticket.save!

      # But with ActionText, we should search differently
      query = Ticket.where(project: project)
      result = query.joins(:rich_text_content).where('action_text_rich_texts.body ILIKE ?', '%content%').to_a
      expect(result).to include(ticket)
    end

    it 'confirms that ActionTextFilter is used for content searches' do
      config = SmartFolderRule.field_config['content']
      expect(config[:filter_class]).to eq('ActionTextFilter')
    end
  end
end
