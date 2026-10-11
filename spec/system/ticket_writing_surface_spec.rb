# frozen_string_literal: true

require 'rails_helper'

# What:  The ticket writing surface in the browser: opened from the list into the
#        layout-owned turbo-frame#writing_surface, closed by Escape only when nothing
#        changed (otherwise a confirm asks first), closed by a save that shows the new
#        ticket - and KEEPS showing it when another ticket was open before.
# Type:  System spec with headless Chrome (doc/inline_bilder_paket_3_plan.md, P3-E3,
#        2026-08-23). Runs by hand: spec/system is not in the CI list.
# Why:   The request spec pins the server side (frames, streams). The protection against
#        losing a half-written description is client-side (neo_writing_surface_controller,
#        form snapshot) and only a real browser can show that Escape on a touched form
#        asks, and that dismissing the question keeps the form standing.
RSpec.describe 'Ticket writing surface', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  def open_surface
    visit organisation_project_tickets_path(organisation, project)
    find('a[href*="/tickets/new"][data-turbo-frame="writing_surface"]', match: :first).click
    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
  end

  it 'opens from the list, closes on Escape when untouched, asks when touched, and saves' do
    open_surface
    expect(page).to have_css('.writing-surface input[name="ticket[title]"]:focus', wait: 5)

    # Untouched: Escape closes at once, nothing asked.
    find('.writing-surface input[name="ticket[title]"]').send_keys(:escape)
    expect(page).to have_no_css('.writing-surface', wait: 5)

    # Touched: Escape asks; dismissing keeps the form and its text.
    open_surface
    find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Halb geschrieben')
    dismiss_confirm(I18n.t('views.organisations.tickets.writing_surface.unsaved_changes')) do
      find('.writing-surface input[name="ticket[title]"]').send_keys(:escape)
    end
    expect(page).to have_css('.writing-surface', wait: 5)
    expect(find('.writing-surface input[name="ticket[title]"]').value).to eq('Halb geschrieben')

    # Accepting closes without saving.
    accept_confirm do
      find('.writing-surface input[name="ticket[title]"]').send_keys(:escape)
    end
    expect(page).to have_no_css('.writing-surface', wait: 5)
    expect(ActsAsTenant.with_tenant(organisation) { Ticket.where(title: 'Halb geschrieben').exists? }).to be(false)

    # Saving clears the surface and shows the new ticket in the list and the detail column.
    open_surface
    find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Gespeichertes Ticket')
    find('.writing-surface button[type="submit"]').click
    expect(page).to have_no_css('.writing-surface', wait: 10)
    expect(page).to have_css('tr[data-ticket-id]', text: 'Gespeichertes Ticket', wait: 10)
    expect(page).to have_css('#ticket_display_frame', text: 'Gespeichertes Ticket', wait: 10)
  end

  # Bug report 23.08.: with a ticket already open, saving a NEW ticket showed the new
  # ticket for a moment and then jumped back to the previously active one.
  it 'keeps showing the new ticket when another ticket was open before' do
    old_ticket = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Altes Ticket', content: '<div>x</div>')
    end

    visit organisation_project_tickets_path(organisation, project)
    find(%(tr[data-ticket-id="#{old_ticket.id}"])).click
    expect(page).to have_css('#ticket_display_frame', text: 'Altes Ticket', wait: 10)

    find('a[href*="/tickets/new"][data-turbo-frame="writing_surface"]', match: :first).click
    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
    find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Frisches Ticket')
    find('.writing-surface button[type="submit"]').click

    expect(page).to have_no_css('.writing-surface', wait: 10)
    expect(page).to have_css('#ticket_display_frame', text: 'Frisches Ticket', wait: 10)
    # The jump arrived AFTER the streams: filter_bar_controller re-visited the page
    # (?ticket_id=<old>) 100ms after any successful submit inside turbo-frame#modal.
    # An immediate assertion is vacuously green, so give the stray visit time to land.
    sleep 2
    expect(page).to have_css('#ticket_display_frame', text: 'Frisches Ticket')
    expect(page).to have_no_css('#ticket_display_frame', text: 'Altes Ticket')
  end

  it 'opens the surface for editing from the detail view and saves the change' do
    ticket = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Alter Titel', content: '<div>x</div>')
    end

    visit organisation_project_ticket_path(organisation, project, ticket)
    find('a[href*="/edit"][data-turbo-frame="writing_surface"]', match: :first).click
    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
    expect(find('.writing-surface input[name="ticket[title]"]').value).to eq('Alter Titel')

    find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Neuer Titel')
    find('.writing-surface button[type="submit"]').click
    expect(page).to have_no_css('.writing-surface', wait: 10)
    expect(page).to have_css('#ticket_display_frame', text: 'Neuer Titel', wait: 10)
    expect(ticket.reload.title).to eq('Neuer Titel')
  end
end
