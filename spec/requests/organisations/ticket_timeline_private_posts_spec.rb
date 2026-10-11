# frozen_string_literal: true

require 'rails_helper'

# What: the ticket timeline shows a private comment only to whom Post.readable_by
#   allows: its author, its addressee and the account admins.
# Why: until 27.09.2026 the timeline rendered every post of the ticket and marked
#   the private ones with a label. Everybody with ticket access read them. The
#   ticket page preloads the posts (optimized_ticket_detail_includes), and the
#   timeline used that loaded association as is, so a filter on the query alone
#   would not have helped.
RSpec.describe 'Private comments in the ticket timeline', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:colleague) { create(:user) }
  let(:admin) { create(:user) }

  let(:public_text) { 'Public remark everyone reads' }
  let(:private_text) { 'Salary figure only for me' }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [author, colleague].each do |user|
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
      end
      create(:membership, user: admin, organisation: organisation,
                          role: Role.find_or_create_account_admin(organisation))
      create(:post, ticket: ticket, user: author, content: public_text)
      create(:post, ticket: ticket, user: author, content: private_text, is_private: true)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def timeline_as(user)
    sign_in user
    get timeline_organisation_project_ticket_path(organisation, project, ticket)
    expect(response).to have_http_status(:ok)
    response.body
  end

  it 'hides the private comment from a colleague with ticket access' do
    body = timeline_as(colleague)

    expect(body).to include(public_text)
    expect(body).not_to include(private_text)
  end

  it 'shows it to its author, with the translated private label' do
    # English on purpose: the German label reads "Privat", the word that used to be hard-coded
    author.update!(language_preference: 'en')
    body = timeline_as(author)

    expect(body).to include(private_text)
    expect(body).to match(%r{bi-lock[^<]*</i>\s*Private\s*<})
  end

  it 'shows it to an account admin' do
    expect(timeline_as(admin)).to include(private_text)
  end

  it 'leaves it out of the item count for the colleague' do
    count = ->(user) { Prosopite.pause { TicketTimelineService.new(ticket.reload, user).timeline_count } }

    expect(count.call(author) - count.call(colleague)).to eq(1)
  end
end
