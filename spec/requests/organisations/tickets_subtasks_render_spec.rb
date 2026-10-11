# frozen_string_literal: true

require 'rails_helper'

# Renders the sub-tasks UI: section + progress on the parent, compact quick-add on a
# childless top-level ticket, and the parent backlink on a child. The SECTION lives
# INSIDE the lazy timeline frame since the T3 follow-up (03.09., ticket detail
# redesign) — the show body only carries the frame's src, so section assertions go
# against the frame's own endpoint; header assertions (backlink badge) stay on show.
RSpec.describe 'Tickets sub-tasks (detail rendering)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def detail_path(ticket)
    # The show route renders the index with @selected_ticket server-side (the index
    # ?ticket_id= param defers the detail to a client-side frame load).
    organisation_project_ticket_path(organisation, project, ticket)
  end

  def subtasks_body(ticket)
    get timeline_organisation_project_ticket_path(organisation, project, ticket)
    response.body
  end

  def create_closed_status_def
    create(:ticket_attribute_definition,
           project: project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
           ] })
  end

  it 'shows the sub-tasks section with progress and child links on the parent' do
    parent = create(:ticket, project: project, creator: user)
    create_closed_status_def
    done_child = create(:ticket, project: project, creator: user, parent: parent, custom_attributes: { 'status' => 'Erledigt' })
    create(:ticket, project: project, creator: user, parent: parent, custom_attributes: { 'status' => 'Offen' })

    body = subtasks_body(parent)

    expect(response).to have_http_status(:ok)
    expect(body).to include("subtasks-#{parent.id}")
    expect(body).to include('1 von 2 erledigt')
    expect(body).to include(done_child.title)
  end

  it 'shows only the compact right-aligned quick-add when there are no sub-tasks (no heading/hint/hero)' do
    lone = create(:ticket, project: project, creator: user)

    body = subtasks_body(lone)

    expect(body).to include('data-controller="subtask-quick-add"')
    # Empty section is the right-aligned affordance, not a full section or a centered hero.
    expect(body).to match(/id="subtasks-#{lone.id}"[^>]*justify-end/)
    expect(body).not_to include('bi-diagram-3')
    expect(body).not_to include('Zerlege diese Aufgabe in kleinere Schritte.')
  end

  it 'shows the parent backlink badge on a child ticket' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    get detail_path(child)

    expect(response.body).to include("Teil von ##{parent.number}")
    expect(response.body).to include('bi-arrow-return-right')
  end

  it 'renders the inline quick-add form posting to this parent subtasks endpoint' do
    lone = create(:ticket, project: project, creator: user)

    body = subtasks_body(lone)

    expect(body).to include('data-controller="subtask-quick-add"')
    expect(body).to include("subtask-quick-add-#{lone.id}")
    expect(body).to include(organisation_project_ticket_subtasks_path(organisation, project, lone))
  end

  it 'renders children in a collapsed <details> when subtasks_display is compact' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)
    ViewConfiguration.for_user_project(user, project, 'tickets')
                     .update!(detail_settings: { 'subtasks_display' => 'compact' })

    body = subtasks_body(parent)

    expect(body).to include('subtasks-details')
    expect(body).to include(child.title)
  end

  it 'renders children expanded (no <details>) in full mode (default)' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    body = subtasks_body(parent)

    expect(body).to include(child.title)
    expect(body).not_to include('subtasks-details')
  end

  it 'does not show the sub-tasks section on a child ticket' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    # Asserted against the frame endpoint — the surface that WOULD render the
    # section if the parent_id gate were missing; the show body never carries it.
    expect(subtasks_body(child)).not_to include("subtasks-#{child.id}")
  end
end
