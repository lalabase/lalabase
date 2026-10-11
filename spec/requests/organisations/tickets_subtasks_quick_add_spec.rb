# frozen_string_literal: true

require 'rails_helper'

# Inline quick-add: POST a title to the parent's subtasks endpoint -> a real child ticket, returned
# as a focused Turbo Stream. Parent comes from the URL (scoped to the project), so a tampered
# parent is a 404 before any write.
RSpec.describe 'Tickets sub-tasks quick-add', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:parent) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def children_of(ticket)
    ActsAsTenant.with_tenant(organisation) { Ticket.where(parent_id: ticket.id).to_a }
  end

  it 'first child: creates it and swaps the empty affordance for the populated section' do
    expect do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Texte liefern' }, as: :turbo_stream
    end.to change { children_of(parent).size }.by(1)

    expect(response).to have_http_status(:ok)
    child = children_of(parent).last
    expect(child.title).to eq('Texte liefern')
    expect(child.project_id).to eq(project.id)
    # Empty -> populated: the whole section is replaced (heading appears), the new row + quick-add are in it.
    expect(response.body).to include('turbo-stream action="replace"')
    expect(response.body).to include('Texte liefern')
    expect(response.body).to include("subtask-quick-add-#{parent.id}")
  end

  it 'subsequent child: appends to the existing list (targeted stream, keeps the input)' do
    create(:ticket, project: project, creator: user, parent: parent) # parent already has a child

    expect do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Bilder besorgen' }, as: :turbo_stream
    end.to change { children_of(parent).size }.by(1)

    expect(response).to have_http_status(:ok)
    # Targeted append before the quick-add row, NOT a full-section replace.
    expect(response.body).to include('turbo-stream action="before"')
    expect(response.body).to include('Bilder besorgen')
  end

  it 'first child for a "compact" user comes back expanded so the next can be typed' do
    ViewConfiguration.for_user_project(user, project, 'tickets')
                     .update!(detail_settings: { 'subtasks_display' => 'compact' })

    post organisation_project_ticket_subtasks_path(organisation, project, parent),
         params: { title: 'Texte liefern' }, as: :turbo_stream

    expect(response).to have_http_status(:ok)
    # The collapsible list is rendered open (not behind the collapsed summary).
    expect(response.body).to match(/<details[^>]*\bopen\b/)
  end

  it 'rejects a blank title: no child, inline error, 422' do
    expect do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: '   ' }, as: :turbo_stream
    end.not_to(change { children_of(parent).size })

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("subtask-error-#{parent.id}")
  end

  it 'returns 404 for a parent that is not in this project (tampered URL), creating nothing' do
    other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    foreign_parent = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: other_project, creator: user) }

    expect do
      post organisation_project_ticket_subtasks_path(organisation, project, foreign_parent),
           params: { title: 'Getampert' }, as: :turbo_stream
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { Ticket.where(parent_id: foreign_parent.id).count } })

    expect(response).to have_http_status(:not_found)
  end

  it 'forbids a member without ticket-write permission (redirect, no child)' do
    reader = create(:user)
    create(:membership, user: reader, organisation: organisation,
                        role: create(:role, organisation: organisation, title: 'Reader'))
    sign_in reader

    expect do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Verboten' }, as: :turbo_stream
    end.not_to(change { children_of(parent).size })

    expect(response).to have_http_status(:found) # Pundit -> user_not_authorized -> redirect
  end
end
