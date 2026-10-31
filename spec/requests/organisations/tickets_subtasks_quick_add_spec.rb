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

  # A new sub-task is a ticket of the list. Which row it takes, and whether the filter shows it at
  # all, only the list's own query knows, so the page reloads the frame from its live address.
  describe 'the ticket list' do
    def reloads_the_list?
      Nokogiri::HTML(response.body).css('turbo-stream').any? do |stream|
        stream['action'] == 'reloadFrame' && stream['target'] == 'tickets_list_frame'
      end
    end

    it 'reloads after the first sub-task' do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Texte liefern' }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(reloads_the_list?).to be(true)
    end

    it 'reloads after a further sub-task' do
      create(:ticket, project: project, creator: user, parent: parent)

      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Bilder besorgen' }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(reloads_the_list?).to be(true)
    end

    it 'stays as it is when nothing was created' do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: '' }, as: :turbo_stream

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('turbo-stream')
      expect(reloads_the_list?).to be(false)
    end
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

  # Sub-tasks nest to any depth: the quick-add on a sub-task makes a grandchild, and the list's
  # Subs cell of that sub-task (its own row, not the root's) gets the new count.
  context 'on a sub-task' do
    let(:sub_task) do
      ActsAsTenant.current_tenant = organisation
      create(:ticket, project: project, creator: user, parent: parent)
    end

    before do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: %w[number title subtask_count],
                                list_columns: { 'cells' => [], 'metadata' => [] },
                                header_columns: %w[assignees])
    end

    def stream_text(target)
      Nokogiri::HTML(response.body).css('turbo-stream').find { |node| node['targets'] == target }&.text&.strip
    end

    it 'creates a grandchild below the sub-task' do
      expect do
        post organisation_project_ticket_subtasks_path(organisation, project, sub_task),
             params: { title: 'Enkel' }, as: :turbo_stream
      end.to change { children_of(sub_task).size }.by(1)

      expect(response).to have_http_status(:ok)
      grandchild = children_of(sub_task).last
      expect(grandchild.title).to eq('Enkel')
      expect(grandchild.parent_id).to eq(sub_task.id)
      expect(response.body).to include("subtask-quick-add-#{sub_task.id}")
    end

    it "redraws the sub-task's own Subs cell and item, not the root's" do
      post organisation_project_ticket_subtasks_path(organisation, project, sub_task),
           params: { title: 'Enkel' }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(stream_text("tr[data-ticket-id='#{sub_task.id}'] td[data-column='subtask_count']")).to eq('0/1')
      expect(stream_text("tr[data-ticket-id='#{sub_task.id}'] .ticket-meta__item[data-meta-column='subtask_count']"))
        .to eq('Subs 0/1')
      expect(stream_text("tr[data-ticket-id='#{parent.id}'] td[data-column='subtask_count']")).to be_nil
    end
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
