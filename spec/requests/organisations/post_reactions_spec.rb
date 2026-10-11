# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket post reactions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:author) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: author) }
  let(:post_record) { create(:post, organisation: organisation, ticket: ticket, user: author) }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'adds a reaction, marks the post read, and consumes its unread notification' do
    notification = create(
      :notification, :ticket_commented,
      organisation: organisation, recipient: user, actor: author,
      notifiable: ticket, project: project,
      payload: { 'post_ids' => [post_record.id.to_s] }
    )
    ticket_updated_at = ticket.reload.updated_at

    expect do
      post organisation_project_ticket_post_reactions_path(organisation, project, ticket, post_record),
           params: { emoji: '👍' },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    end.to change { PostReaction.unscoped.count }.by(1)
                                                 .and change { PostRead.unscoped.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('👍')
    expect(notification.reload).to be_state_read
    expect(ticket.reload.updated_at).to eq(ticket_updated_at)
    streams = Nokogiri::HTML.fragment(response.body)
    indicator = streams.at_css("turbo-stream[targets=\"[data-ticket-unread-for='#{ticket.id}']\"]")
    expect(indicator).to be_present
    expect(indicator.at_css('[role="img"]')).to be_nil
    expect(streams.css('tr')).to be_empty
    expect(streams.css('turbo-stream').map { |stream| stream['targets'] })
      .not_to include("tr[data-ticket-id='#{ticket.id}']")
  end

  it 'is idempotent for the same emoji but still marks the post read' do
    create(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '✅')

    expect do
      post organisation_project_ticket_post_reactions_path(organisation, project, ticket, post_record),
           params: { emoji: '✅' }
    end.not_to(change { PostReaction.unscoped.count })

    expect(response).to redirect_to(organisation_project_ticket_path(
                                      organisation, project, ticket, anchor: "post_#{post_record.id}"
                                    ))
    expect(PostRead.unscoped.find_by(post: post_record, user: user)).to be_present
  end

  it 'removes the own reaction without making the post unread again' do
    reaction = create(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '👀')
    read = create(:post_read, organisation: organisation, post: post_record, user: user)

    expect do
      delete organisation_project_ticket_post_reaction_path(
        organisation, project, ticket, post_record, reaction
      )
    end.to change { PostReaction.unscoped.count }.by(-1)

    expect(PostRead.unscoped.count).to eq(1)
    expect(PostRead.unscoped.find_by(id: read.id)).to be_present
  end

  it 'rejects unsupported emoji without recording a read receipt' do
    expect do
      post organisation_project_ticket_post_reactions_path(organisation, project, ticket, post_record),
           params: { emoji: '🚫' }
    end.not_to(change { [PostReaction.unscoped.count, PostRead.unscoped.count] })

    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'does not let a ticket reader create a reaction' do
    sign_out user
    reader = create(:user)
    role = create(:role, title: 'Ticket-Leser', organisation: organisation)
    create(:project_read_permission, role: role, area: 'tickets')
    create(:membership, user: reader, organisation: organisation, role: role, active: true)
    sign_in reader

    expect do
      post organisation_project_ticket_post_reactions_path(organisation, project, ticket, post_record),
           params: { emoji: '👍' }
    end.not_to(change { [PostReaction.unscoped.count, PostRead.unscoped.count] })
  end

  it "does not let a writer remove another user's reaction" do
    reaction = create(:post_reaction, organisation: organisation, post: post_record, user: author)

    expect do
      delete organisation_project_ticket_post_reaction_path(
        organisation, project, ticket, post_record, reaction
      )
    end.not_to(change { PostReaction.unscoped.count })

    expect(response).to have_http_status(:not_found)
  end
end
