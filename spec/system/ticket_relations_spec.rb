# frozen_string_literal: true

require 'rails_helper'

# Ticket relations on the ticket page, clicked for real (doc/ticket_relations_plan.md,
# revision 4, §8.2 and §12). Markup assertions cannot prove what these do: the modal opening
# from a menu and from the section, the picker searching the server, the streams landing
# without a page change, and where a link goes, in the lane of the table and the board, on a
# phone and in the inbox pane. A link into the same project stays in the lane; one into
# another project opens that ticket's own page (URL, project, edit, back).
RSpec.describe 'Ticket relations on the ticket page', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Kundenportal') }
  let(:other_project) { create(:project, organisation: organisation, name: 'Backoffice') }
  let(:rs) { 'views.organisations.tickets.shared.relations' }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                        active: true)
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:ticket) { create(:ticket, project: project, title: 'Checkout bricht ab', creator: user) }
  let!(:blocker) { create(:ticket, project: other_project, title: 'Zahlungsanbieter wechseln', creator: user) }
  let!(:neighbour) { create(:ticket, project: project, title: 'Warenkorb aufraeumen', creator: user) }

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane_path(of = ticket, **params)
    organisation_project_tickets_path(organisation, of.project, ticket_id: of.id, **params)
  end

  def section_css(of = ticket)
    "#ticket-relations-#{of.id}"
  end

  def hint_css(of = ticket)
    "#ticket-waiting-#{of.id}"
  end

  def link(source, target, type)
    TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type)
  end

  # A full page load resets window; a Turbo stream or a frame visit keeps it.
  def mark_page
    page.execute_script('window.__relationsPageMark = true')
  end

  def same_page?
    page.evaluate_script('window.__relationsPageMark === true')
  end

  def open_modal_from_menu(scope = '#ticket-header')
    within(scope) do
      find(:button, title: I18n.t('views.organisations.tickets.ticket_header_show.more_actions')).click
      click_link I18n.t("#{rs}.menu_link")
    end
    expect(page).to have_css('[role="dialog"]')
  end

  def pick_and_link(kind, term, option_text)
    within('[role="dialog"]') do
      select I18n.t("#{rs}.kinds.#{kind}"), from: I18n.t("#{rs}.modal.kind")
      fill_in I18n.t("#{rs}.modal.ticket"), with: term
      find('[role="option"]', text: option_text).click
      expect(page).to have_field(I18n.t("#{rs}.modal.ticket"), with: option_text)
      click_button I18n.t("#{rs}.modal.submit")
    end
  end

  def expect_modal_closed
    expect(page).to have_no_css('[role="dialog"]')
    expect(page.evaluate_script('document.body.classList.contains("overflow-hidden")')).to be(false)
  end

  describe 'in the lane of the ticket table' do
    it 'links a ticket of another project without a page change, removes it, and links it again' do
      visit lane_path
      expect(page).to have_css('#tickets_list_frame table')
      mark_page

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      expect_modal_closed

      within(section_css) do
        expect(page).to have_content(I18n.t("#{rs}.kinds.blocked_by"))
        expect(page).to have_content('Zahlungsanbieter wechseln')
        expect(page).to have_content('Backoffice')
      end
      within(hint_css) { expect(page).to have_link(blocker.display_title) }
      expect(same_page?).to be(true)
      stored = TicketRelation.sole
      expect([stored.source_ticket_id, stored.target_ticket_id, stored.relation_type]).to eq([blocker.id, ticket.id, 'blocks'])

      # The last relation goes: section and hint go with it, their containers stay.
      within(section_css) do
        accept_confirm { find("button[aria-label='#{I18n.t("#{rs}.remove")}']").click }
      end
      expect(page).to have_no_css("#{section_css} li")
      expect(page).to have_css("#{hint_css}.hidden", visible: :all)
      expect(TicketRelation.count).to eq(0)

      # And the first again, into the containers the last one left.
      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      expect_modal_closed
      within(section_css) { expect(page).to have_content('Zahlungsanbieter wechseln') }
      within(hint_css) { expect(page).to have_link(blocker.display_title) }
      expect(same_page?).to be(true)
    end

    # Review round 4 of #944: the jump from the hint to the section was a native #anchor. It
    # pushed a history entry, Back reloaded the lane, and the hash went into later addresses.
    it 'jumps from the hint to the section without touching the address or the history' do
      link(neighbour, ticket, :blocks)
      link(blocker, ticket, :precedes)
      visit lane_path
      history = page.evaluate_script('window.history.length')
      address = page.current_url

      within(hint_css) { find('button[data-controller="scroll-into-view"]').click }

      expect(page).to have_css("#{section_css}:focus")
      expect(page.current_url).to eq(address)
      expect(page.evaluate_script('window.location.hash')).to eq('')
      expect(page.evaluate_script('window.history.length')).to eq(history)

      # Review round 5 of #944: the tabindex that made the section focusable goes with the
      # focus. Left in place, the section took the focus of every click inside it (Safari
      # does not focus links on click), and the modal took it for its trigger.
      page.send_keys(:tab)
      expect(page).to have_no_css("#{section_css}:focus")
      expect(page).to have_no_css("#{section_css}[tabindex]")
    end

    # Review round 4 of #944: two people on one ticket; the other one removed the relation,
    # this page was not told. The X answered with a bare 404 page and the frame showed
    # "Content missing" where the ticket was. Now the section comes back as it is, with the
    # reason in a flash, and the ticket stays on screen.
    it 'answers an X on a relation removed meanwhile with the current section' do
      stale = link(blocker, ticket, :blocks)
      link(ticket, neighbour, :relates_to)
      visit lane_path
      within(section_css) { expect(page).to have_content('Zahlungsanbieter wechseln') }

      Actors::DestroyTicketRelation.call(ticket: ticket, relation_id: stale.id, current_user: user)
      within("#{section_css} li[data-relation-id='#{stale.id}']") do
        accept_confirm { find("button[aria-label='#{I18n.t("#{rs}.remove")}']").click }
      end

      expect(page).to have_content(I18n.t('services.actors.destroy_ticket_relation.not_found'))
      within(section_css) do
        expect(page).to have_no_content('Zahlungsanbieter wechseln')
        expect(page).to have_content('Warenkorb aufraeumen')
      end
      expect(page).to have_no_content('Content missing')
      within('#ticket_display_frame') { expect(page).to have_css('h2', text: 'Checkout bricht ab') }
    end

    it 'opens the same modal from "+ Link" in the section' do
      link(ticket, neighbour, :relates_to)
      visit lane_path

      within(section_css) { click_link I18n.t("#{rs}.add") }
      within('[role="dialog"]') do
        # The delay field only for "precedes" and "follows".
        expect(page).to have_no_field(I18n.t("#{rs}.modal.delay_days"))
        select I18n.t("#{rs}.kinds.precedes"), from: I18n.t("#{rs}.modal.kind")
        fill_in I18n.t("#{rs}.modal.delay_days"), with: '2'
        select I18n.t("#{rs}.kinds.relates_to"), from: I18n.t("#{rs}.modal.kind")
        expect(page).to have_no_field(I18n.t("#{rs}.modal.delay_days"))
      end
      pick_and_link('precedes', 'Zahlungs', blocker.display_title)
      expect_modal_closed

      within(section_css) do
        expect(page).to have_content('Zahlungsanbieter wechseln')
        expect(page).to have_content(I18n.t("#{rs}.delay", count: 2, days: '+2'))
      end
      expect(TicketRelation.find_by(source_ticket: ticket, target_ticket: blocker).delay_days).to eq(2)
    end

    it 'shows a refused save in the modal, keeps the picked ticket, and saves once corrected' do
      link(ticket, blocker, :blocks)
      visit lane_path

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)

      within('[role="dialog"]') do
        expect(page).to have_content(I18n.t('services.actors.create_ticket_relation.would_create_cycle'))
        expect(page).to have_field(I18n.t("#{rs}.modal.ticket"), with: blocker.display_title)
        select I18n.t("#{rs}.kinds.relates_to"), from: I18n.t("#{rs}.modal.kind")
        # application.js drops a request identical to one of the last 500 ms (same method,
        # address and frame) as a double click. A person reads the message first; the robot
        # would be faster than that window.
        sleep 0.6
        click_button I18n.t("#{rs}.modal.submit")
      end
      expect_modal_closed
      within(section_css) { expect(page).to have_content(I18n.t("#{rs}.kinds.relates_to")) }
    end

    it 'closes the picker list first and the modal on the second Escape' do
      visit lane_path
      open_modal_from_menu

      fill_in I18n.t("#{rs}.modal.ticket"), with: 'Zahlungs'
      expect(page).to have_css('[role="option"]', text: blocker.display_title)
      # To the focused field, the way a person presses it: an element's send_keys clicks it
      # first, and a click opens the list again.
      page.send_keys(:escape)
      expect(page).to have_no_css('[role="option"]')
      expect(page).to have_css('[role="dialog"]')
      # The lane behind the modal stays open (layout-toggle leaves Escape to the modal).
      expect(page).to have_css('#ticket_display_frame h2', text: 'Checkout bricht ab')

      page.send_keys(:escape)
      expect_modal_closed
      expect(page).to have_css('#ticket_display_frame h2', text: 'Checkout bricht ab')
    end

    # Review of #944: the answer to a save came back after the modal was closed, filled the
    # frame again and locked the page's scrolling. Now it finds no instance and does nothing.
    it 'keeps a closed modal closed when a late refusal arrives' do
      link(ticket, blocker, :blocks)
      allow_any_instance_of(Organisations::Tickets::RelationsController).to receive(:create).and_wrap_original do |original|
        sleep 1
        original.call
      end
      visit lane_path

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      find("button[aria-label='#{I18n.t("#{rs}.modal.close")}']").click
      expect_modal_closed

      # Nothing on the page says when the late answer has landed; it takes a second.
      sleep 2
      expect_modal_closed
      expect(TicketRelation.count).to eq(1)
    end

    # Review round 3 of #944: the lane was closed while the modal was still loading. The late
    # answer put the modal into the hidden detail and locked the page's scrolling, with
    # nothing on screen to close it. A modal that arrives unseen now discards itself.
    it 'does not open a modal that arrives after its lane was closed' do
      allow_any_instance_of(Organisations::Tickets::RelationsController).to receive(:new).and_wrap_original do |original|
        sleep 1
        original.call
      end
      visit lane_path

      within('#ticket-header') do
        find(:button, title: I18n.t('views.organisations.tickets.ticket_header_show.more_actions')).click
        click_link I18n.t("#{rs}.menu_link")
      end
      page.send_keys(:escape)
      expect(page).to have_css('.layout.hide-content')

      # Nothing on the page says when the late answer has landed; it takes a second.
      sleep 2
      expect(page.evaluate_script('document.body.classList.contains("overflow-hidden")')).to be(false)
      expect(page).to have_no_css('[data-controller~="ticket-relation-modal"]', visible: :all)
    end

    # Review of #944: saving removed the focused button and left the focus on the page body.
    it 'returns the focus to "+ Link" after a save, although the stream replaced it' do
      link(ticket, neighbour, :relates_to)
      visit lane_path

      within(section_css) { click_link I18n.t("#{rs}.add") }
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)

      expect_modal_closed
      expect(page).to have_css("#ticket-relations-add-#{ticket.id}:focus")
    end

    # Review of #944: after a refused save the new modal took the page body for the trigger,
    # so a later cancel lost the focus as well.
    it 'returns the focus to the menu button after a refusal and a cancel' do
      link(ticket, blocker, :blocks)
      visit lane_path

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      within('[role="dialog"]') do
        expect(page).to have_content(I18n.t('services.actors.create_ticket_relation.would_create_cycle'))
        click_button I18n.t("#{rs}.modal.cancel")
      end

      expect_modal_closed
      expect(page).to have_css("#ticket-more-actions-#{ticket.id}:focus")
    end

    # The frame keeps the trigger, not the instance: the instance after the refusal would
    # only know the page body and fall back to the menu button.
    it 'returns the focus to "+ Link" after a refusal and a cancel' do
      link(ticket, blocker, :blocks)
      visit lane_path

      within(section_css) { click_link I18n.t("#{rs}.add") }
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      within('[role="dialog"]') do
        expect(page).to have_content(I18n.t('services.actors.create_ticket_relation.would_create_cycle'))
        click_button I18n.t("#{rs}.modal.cancel")
      end

      expect_modal_closed
      expect(page).to have_css("#ticket-relations-add-#{ticket.id}:focus")
    end

    it 'returns the focus to the menu button after a save from the menu' do
      visit lane_path

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)

      expect_modal_closed
      expect(page).to have_css("#ticket-more-actions-#{ticket.id}:focus")
    end

    it 'follows a link into another project to the full page of that ticket, and back' do
      link(blocker, ticket, :blocks)
      visit lane_path

      within(section_css) { click_link 'Zahlungsanbieter wechseln' }

      expect(page).to have_current_path(lane_path(blocker))
      within('#ticket_display_frame') { expect(page).to have_css('h2', text: 'Zahlungsanbieter wechseln') }
      within('#tickets_list_frame') { expect(page).to have_content('Zahlungsanbieter wechseln') }
      expect(page).to have_css(%(a[href="#{edit_organisation_project_ticket_path(organisation, other_project, blocker)}"]))
      expect(page).to have_css('#sidebar', text: 'Backoffice')

      # Back is a Turbo restoration visit that fetches the page again (tickets are not cached);
      # the address changes first, the page follows.
      page.go_back
      expect(page).to have_current_path(lane_path)
      expect(page).to have_css('#ticket_display_frame h2', text: 'Checkout bricht ab')
      expect(page).to have_css('#tickets_list_frame', text: 'Warenkorb aufraeumen')
    end

    it 'keeps a link into the same project in the lane' do
      link(ticket, neighbour, :relates_to)
      visit lane_path
      mark_page

      within(section_css) { click_link 'Warenkorb aufraeumen' }

      within('#ticket_display_frame') { expect(page).to have_css('h2', text: 'Warenkorb aufraeumen') }
      expect(page).to have_css('#tickets_list_frame table')
      expect(same_page?).to be(true)
    end
  end

  describe 'in the lane of the board' do
    before do
      # The board lays the cards out by status: a project without one shows no card.
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
      ticket.update!(custom_attributes: { 'status' => 'Neu' })
      ViewConfiguration.create!(user: user, project: project, organisation: organisation,
                                view_type: 'tickets', view_mode: 'kanban',
                                table_columns: %w[number title], header_columns: %w[assignees],
                                list_columns: { 'cells' => [], 'metadata' => [] })
    end

    it 'links from the lane beside the board and follows the link into the other project' do
      visit lane_path
      expect(page).to have_css("#kanban-card-#{ticket.id}")
      mark_page

      open_modal_from_menu
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      expect_modal_closed
      within(section_css) { expect(page).to have_content('Zahlungsanbieter wechseln') }
      expect(same_page?).to be(true)

      within(section_css) { click_link 'Zahlungsanbieter wechseln' }
      expect(page).to have_current_path(lane_path(blocker))
      within('#ticket_display_frame') { expect(page).to have_css('h2', text: 'Zahlungsanbieter wechseln') }
    end
  end

  describe 'on a phone' do
    before do
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride',
                                      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    end

    after { page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride') }

    it 'links from the ticket detail and follows the link into the other project' do
      visit lane_path(viewport: 'mobile')
      expect(page).to have_css('.mobile-ticket-detail')

      open_modal_from_menu('.mobile-ticket-detail #ticket-header')
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      expect_modal_closed
      within(section_css) { expect(page).to have_content('Zahlungsanbieter wechseln') }
      overflow = page.evaluate_script('document.documentElement.scrollWidth > window.innerWidth')
      expect(overflow).to be(false)

      within(section_css) { click_link 'Zahlungsanbieter wechseln' }
      expect(page).to have_current_path(lane_path(blocker))
      expect(page).to have_css('h2', text: 'Zahlungsanbieter wechseln')
    end
  end

  describe 'in the inbox pane' do
    it 'links from the pane and follows the link into the other project' do
      notification = create(:notification, recipient: user, organisation: organisation, project: project,
                                           notifiable: ticket, event_type: 'ticket_assigned', channel: 'in_app',
                                           state: :delivered)
      visit organisation_notifications_path(organisation, state_filters: ['unread'])
      find("[data-notification-item='#{notification.id}'] a", match: :first).click
      within('#ticket_pane') { expect(page).to have_css('h2', text: 'Checkout bricht ab') }
      mark_page

      open_modal_from_menu('#ticket_pane #ticket-header')
      pick_and_link('blocked_by', 'Zahlungs', blocker.display_title)
      expect_modal_closed
      within("#ticket_pane #{section_css}") { expect(page).to have_content('Zahlungsanbieter wechseln') }
      expect(same_page?).to be(true)

      within("#ticket_pane #{section_css}") { click_link 'Zahlungsanbieter wechseln' }
      expect(page).to have_current_path(lane_path(blocker))
      within('#ticket_display_frame') { expect(page).to have_css('h2', text: 'Zahlungsanbieter wechseln') }
    end
  end
end
