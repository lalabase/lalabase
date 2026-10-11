# frozen_string_literal: true

require 'rails_helper'

# Inbox system specs — the thin, browser-/JS-dependent layer of the
# QA matrix (see doc/inbox_qa_matrix.md). Backend/filter/pagination
# logic is covered in the request specs; here only what needs a real
# browser (Turbo frame, Stimulus, IntersectionObserver, timer).
#
# Driver switchable via ENV (see matrix docs):
#   Default              → Selenium headless (CSS/JS-faithful)
#   E2E_DRIVER=playwright → Playwright engine
RSpec.describe 'Inbox (System)', type: :system, inbox_e2e: true do
  # Pre-existing N+1 in the full-page renders (Notification → .organisation
  # per item). Not the scope of these E2E specs. Before the let!/before, so that
  # the data setup is not scanned.
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    login_as(user, scope: :user)
  end

  def create_notification(state:, ticket:, created_at: 1.hour.ago)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation,
             project: project, notifiable: ticket,
             event_type: 'ticket_assigned', channel: 'in_app', state: state,
             read_at: %i[read archived].include?(state) ? created_at : nil,
             archived_at: state == :archived ? created_at : nil,
             created_at: created_at)
    end
  end

  def inbox_path(**params)
    organisation_notifications_path(organisation, **params)
  end

  # B1 — Clicking a ticket notification loads the ticket in the pane.
  it 'lädt das Ticket im Pane beim Klick (B1)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Login-Bug') }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find("[data-notification-item='#{n.id}'] a", match: :first).click

    within('#ticket_pane') do
      expect(page).to have_content('Login-Bug')
    end
  end

  # B2 — Delayed mark-as-read: after ~5s the item leaves the
  # unread filter. Generous wait time (5s timer + network).
  it 'entfernt das Item nach verzögertem Mark-as-read aus dem Unread-Filter (B2)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Verzögert') }
    n = create_notification(state: :delivered, ticket: ticket)

    visit inbox_path(state_filters: ['unread'])
    find("[data-notification-item='#{n.id}'] a", match: :first).click

    expect(page).to have_css('#ticket_pane', text: 'Verzögert')
    # After the 5s timer elapses, the (now read) notification is gone.
    expect(page).not_to have_css("[data-notification-item='#{n.id}']", wait: 9)
  end

  # C2 — "Select all" selects all visible items.
  it 'selektiert alle Items via "Alle auswählen" (C2)' do
    tickets = ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 3, project: project) }
    tickets.each_with_index { |t, i| create_notification(state: :delivered, ticket: t, created_at: (i + 1).hours.ago) }

    visit inbox_path(state_filters: ['unread'])
    check('Alle auswählen', allow_label_click: true)

    expect(page).to have_css('[data-inbox-bulk-select-target="bar"]', visible: true)
    expect(page).to have_content('3 ausgewählt')
  end

  # C7 — Bulk archive empties the list → empty state appears.
  it 'zeigt Empty-State nachdem Bulk-Archive die Liste leert (C7)' do
    tickets = ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 2, project: project) }
    tickets.each_with_index { |t, i| create_notification(state: :delivered, ticket: t, created_at: (i + 1).hours.ago) }

    visit inbox_path(state_filters: ['unread'])
    check('Alle auswählen', allow_label_click: true)
    within('[data-inbox-bulk-select-target="bar"]') { click_button('Archivieren') }

    expect(page).to have_content('Keine Benachrichtigungen gefunden', wait: 6)
  end

  # D1 — Advanced filter auto-submits on change. Picking a project in the
  # expandable "Erweiterte Filter" panel must narrow the list immediately,
  # without a submit button. Regression: the Stimulus controller is mounted
  # ON the <form>, so submitForm() must use the form element itself — looking
  # for a *descendant* <form> returned null and the change never submitted.
  it 'wendet den Projektfilter sofort an, wenn ein Projekt im erweiterten Filter gewählt wird (Auto-Submit)' do
    project_b = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Calc') }
    ticket_a  = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Aufgabe A') }
    ticket_b  = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project_b, title: 'Aufgabe B') }
    n_a = create_notification(state: :delivered, ticket: ticket_a, created_at: 1.hour.ago)
    n_b = ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation,
             project: project_b, notifiable: ticket_b,
             event_type: 'ticket_assigned', channel: 'in_app', state: :delivered,
             read_at: nil, created_at: 2.hours.ago)
    end

    # Pre-open the advanced-filter panel via a shared event_type (both
    # notifications are ticket_assigned, so neither is hidden). This isolates
    # the auto-submit behaviour from the panel-toggle Stimulus timing.
    visit inbox_path(state_filters: ['unread'], event_type: 'ticket_assigned')
    expect(page).to have_css("[data-notification-item='#{n_a.id}']")
    expect(page).to have_css("[data-notification-item='#{n_b.id}']")
    expect(page).to have_select('project_id', visible: true)

    # Pick project B — no submit button; the change must auto-submit.
    select 'Calc', from: 'project_id'

    # Auto-submit must narrow the list to project B only.
    expect(page).to have_css("[data-notification-item='#{n_b.id}']", wait: 6)
    expect(page).to have_no_css("[data-notification-item='#{n_a.id}']")
  end

  # F4 — Endless scroll loads further pages, no duplicates.
  it 'lädt weitere Seiten via Endless-Scroll nach (F4)' do
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
    60.times { |i| create_notification(state: :delivered, ticket: ticket, created_at: (i + 1).minutes.ago) }

    visit inbox_path(state_filters: ['unread'], view_mode: 'chronological')
    expect(page).to have_css('[data-notification-item]', count: 50)

    # Scroll the sentinel into the viewport → IntersectionObserver triggers loadMore.
    page.execute_script(<<~JS)
      document.querySelector('[data-neo-endless-scroll-target="sentinel"]')
              ?.scrollIntoView({ block: 'center' });
    JS

    expect(page).to have_css('[data-notification-item]', count: 60, wait: 8)
  end
end
