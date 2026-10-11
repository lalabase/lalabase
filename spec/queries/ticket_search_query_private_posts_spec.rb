# frozen_string_literal: true

require 'rails_helper'

# What: a word that only a private comment (or its attachment) contains finds the
#   ticket for those Post.readable_by lets read it, and for nobody else.
# Why: until 27.09.2026 all four post joins of the search took every post of the
#   ticket, so a colleague could probe a private comment word by word. The
#   dashboard widget runs the same query and did not even pass the user.
RSpec.describe TicketSearchQuery, 'and private comments', :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Quarterly planning') }
  let(:author) { create(:user) }
  let(:colleague) { create(:user) }

  # Long enough for the full-text path, short enough (2 chars) for the ILIKE path
  let(:comment_word) { 'Gehaltszahl' }
  let(:attachment_word) { 'Kündigungsfrist' }
  let(:short_word) { 'qx' }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [author, colleague].each do |user|
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
      end
      post = create(:post, ticket: ticket, user: author, is_private: true,
                           content: "Die #{comment_word} ist #{short_word}7")
      create(:post_document, post: post, organisation: organisation)
        .update_column(:plain_text_version, "Die #{attachment_word} beträgt drei Monate")
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def finds?(term, mode, user)
    described_class.new(project, { search: term, search_mode: mode }, { current_user: user })
                   .call.to_a.include?(ticket)
  end

  {
    'a comment word, full-text path' => [:comment_word, %w[content full]],
    'a comment word, short-term ILIKE path' => [:short_word, %w[content full]],
    'an attachment word, full-text path' => [:attachment_word, %w[full]]
  }.each do |label, (word, modes)|
    modes.each do |mode|
      context "with #{label} in #{mode} mode" do
        it 'finds nothing for a colleague' do
          expect(finds?(public_send(word), mode, colleague)).to be(false)
        end

        it 'finds the ticket for the author' do
          expect(finds?(public_send(word), mode, author)).to be(true)
        end
      end
    end
  end

  it 'finds nothing private without a user' do
    expect(finds?(comment_word, 'content', nil)).to be(false)
  end

  it 'passes the viewer on from the dashboard widget' do
    search = lambda do |user|
      Dashboard::RecentTicketsComponent.new(project: project, user: user, search_query: comment_word)
                                       .send(:search_relation).to_a
    end

    expect(search.call(author)).to include(ticket)
    expect(search.call(colleague)).not_to include(ticket)
  end
end
