# frozen_string_literal: true

require 'rails_helper'

# The options of the ticket view, shared by MCP get_ticket and the REST ticket
# view. The pages themselves are pinned through both surfaces
# (get_ticket_paging_spec.rb, spec/requests/api/v1/ticket_view_spec.rb).
RSpec.describe Tickets::Reading do
  describe '.options' do
    it 'defaults to the first page of 50, oldest first' do
      options = described_class.options({})
      expect(options.to_h).to eq(posts_page: 1, posts_per_page: 50, newest: false, attachments_page: 1)
    end

    it 'reads strings as well as integers' do
      options = described_class.options({ posts_page: '2', posts_per_page: 3, posts_order: 'newest', attachments_page: ' 4 ' })
      expect(options.to_h).to eq(posts_page: 2, posts_per_page: 3, newest: true, attachments_page: 4)
    end

    it 'treats a blank value like a missing one' do
      expect(described_class.options({ posts_page: ' ', posts_order: '' }).to_h)
        .to eq(posts_page: 1, posts_per_page: 50, newest: false, attachments_page: 1)
    end

    it 'clamps posts_per_page above 50 for MCP and refuses it for REST' do
      expect(described_class.options({ posts_per_page: 51 }, over_max: :clamp).posts_per_page).to eq(50)
      expect(described_class.options({ posts_per_page: 50 }, over_max: :refuse).posts_per_page).to eq(50)
      expect { described_class.options({ posts_per_page: '51' }, over_max: :refuse) }
        .to raise_error(described_class::InvalidOption, /posts_per_page "51" \(1 to 50\)/)
    end

    {
      { posts_page: 0 } => /posts_page 0/,
      { posts_page: '100001' } => /posts_page/,
      { posts_page: 'abc' } => /posts_page "abc"/,
      { posts_page: ['1'] } => /posts_page/,
      { posts_per_page: 0 } => /posts_per_page 0/,
      { posts_order: 'random' } => /posts_order "random"/,
      { attachments_page: -1 } => /attachments_page -1/
    }.each do |args, message|
      it "refuses #{args.inspect}" do
        expect { described_class.options(args) }.to raise_error(described_class::InvalidOption, message)
      end
    end
  end

  describe '.paging_requested?' do
    it 'is switched on by any one of the four options, even empty' do
      described_class::PAGING_KEYS.each do |key|
        expect(described_class.paging_requested?(ActionController::Parameters.new(key => ''))).to be(true)
      end
      expect(described_class.paging_requested?(ActionController::Parameters.new(full_text: 'true'))).to be(false)
    end
  end
end
