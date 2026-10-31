# frozen_string_literal: true

require 'rails_helper'

# Renders the sub-tasks UI: section + progress on a ticket with children, compact
# quick-add on a childless one, and the trail of ancestors on a sub-task. Sub-tasks
# nest to any depth, so every ticket, a sub-task too, carries the section. The
# SECTION lives INSIDE the lazy timeline frame since the T3 follow-up (03.09., ticket
# detail redesign) - the show body only carries the frame's src, so section
# assertions go against the frame's own endpoint; header assertions (the trail)
# stay on show.
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

  # The section sits inside the turbo frame of the timeline. A link without a target stays in
  # that frame, the answer holds no such frame, and the reader gets "Content missing".
  it 'opens a sub-task from the list in the detail frame, not in the timeline frame' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    link = Nokogiri::HTML(subtasks_body(parent)).at_css("a[href*='ticket_id=#{child.id}']")

    expect(response).to have_http_status(:ok)
    expect(link).to be_present
    expect(link['data-turbo-frame']).to eq('ticket_display_frame')
    expect(link.key?('data-ticket-link')).to be(true)
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

  def breadcrumbs(body = response.body)
    Nokogiri::HTML(body).at_css(
      "nav[aria-label='#{I18n.t('views.organisations.tickets.shared.subtasks.breadcrumbs_label')}']"
    )
  end

  it 'shows the parent number as a link in the trail of a child, and no old pill' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    get detail_path(child)

    expect(response).to have_http_status(:ok)
    nav = breadcrumbs
    expect(nav).to be_present
    link = nav.at_css('ol li a')
    expect(link.text.strip).to eq("##{parent.number}")
    expect(link['href']).to eq(organisation_project_tickets_path(organisation, project, ticket_id: parent.id))
    expect(link.key?('data-ticket-link')).to be(true)
    expect(response.body).not_to include('Teil von')
  end

  it 'shows the whole chain of a great-grandchild, root first, its own number last and not a link' do
    root = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: root)
    grandchild = create(:ticket, project: project, creator: user, parent: child)
    great = create(:ticket, project: project, creator: user, parent: grandchild)

    get detail_path(great)

    expect(response).to have_http_status(:ok)
    items = breadcrumbs.css('ol > li')
    expect(items.map { |li| li.text.gsub(/\s+/, ' ').strip.delete_suffix('›').strip })
      .to eq([root, child, grandchild, great].map { |t| "##{t.number}" })
    expect(items[0..2].map { |li| li.at_css('a')['href'] })
      .to eq([root, child, grandchild].map { |t| organisation_project_tickets_path(organisation, project, ticket_id: t.id) })
    expect(items.last.at_css('a')).to be_nil
    expect(items.last.at_css('[aria-current="page"]').text.strip).to eq("##{great.number}")
    # The separator is decoration, not a word a screen reader reads out.
    expect(breadcrumbs.css('[aria-hidden="true"]').map { |n| n.text.strip }).to eq(%w[› › ›])
  end

  it 'looks the ancestors up in one query, however deep the ticket sits' do
    root = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: root)
    grandchild = create(:ticket, project: project, creator: user, parent: child)
    great = create(:ticket, project: project, creator: user, parent: grandchild)

    statements = capture_sql { get detail_path(great) }

    expect(response).to have_http_status(:ok)
    expect(statements.grep(/WITH RECURSIVE ancestors/).size).to eq(1)
  end

  # The header asks the database, not parent_id: a parent the walk cannot reach (deleted
  # meanwhile, or legacy data in another project) leaves no ancestors, and a trail of the
  # ticket's own number alone would say nothing. Written past the model on purpose.
  it 'shows no trail when the parent lies in another project' do
    other_project = create(:project, organisation: organisation)
    foreign = create(:ticket, project: other_project, creator: user)
    orphan = create(:ticket, project: project, creator: user)
    orphan.update_column(:parent_id, foreign.id)

    statements = capture_sql { get detail_path(orphan) }

    expect(response).to have_http_status(:ok)
    expect(breadcrumbs).to be_nil
    expect(response.body).not_to include("##{foreign.number}</a>")
    expect(statements.grep(/WITH RECURSIVE ancestors/).size).to eq(1)
  end

  it 'shows no trail on a top-level ticket' do
    lone = create(:ticket, project: project, creator: user)

    get detail_path(lone)

    expect(response).to have_http_status(:ok)
    expect(breadcrumbs).to be_nil
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

  it 'shows the sub-tasks section and its quick-add on a child ticket too' do
    parent = create(:ticket, project: project, creator: user)
    child = create(:ticket, project: project, creator: user, parent: parent)

    body = subtasks_body(child)

    expect(response).to have_http_status(:ok)
    expect(body).to include("subtasks-#{child.id}")
    expect(body).to include("subtask-quick-add-#{child.id}")
    expect(body).to include(organisation_project_ticket_subtasks_path(organisation, project, child))
    expect(body).to include('data-timeline-filter-target="subtasksToggleButton"')
  end
end
