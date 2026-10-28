# frozen_string_literal: true

require 'rails_helper'

# The waiting state outside the ticket page, clicked for real (doc/ticket_relations_plan.md,
# revision 4, §8.3, §8.4, §12): the "Wartet" column chosen in the picker, the open ticket's own
# row and card following a relation added and removed in the lane beside them without a page
# change, the hourglass on the board and on a phone. The request specs prove the markup; these
# prove that the streams land and the column fits.
#
# A blocker done elsewhere does not reach the rows that wait on it until the list is loaded
# again (plan §4, no stream for another ticket): the table test reloads for that on purpose.
RSpec.describe 'Waiting state in the list, on the board and on a phone', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Kundenportal') }
  let(:other_project) { create(:project, organisation: organisation, name: 'Backoffice') }
  let(:rs) { 'views.organisations.tickets.shared.relations' }
  let(:view_mode) { 'table' }
  let(:table_columns) { %w[number title] }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                        active: true)
    [project, other_project].each do |each_project|
      create(:ticket_attribute_definition,
             project: each_project, name: 'status', field_type: 'select', system: true,
             options: { 'allowed_values' => [
               { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
             ] })
    end
    ViewConfiguration.create!(user: user, project: project, organisation: organisation, view_type: 'tickets',
                              view_mode: view_mode, table_columns: table_columns, header_columns: %w[assignees],
                              list_columns: { 'cells' => [], 'metadata' => [] })
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:ticket) { create(:ticket, project: project, title: 'Checkout bricht ab', creator: user, custom_attributes: { 'status' => 'Offen' }) }
  let!(:blocker) do
    create(:ticket, project: other_project, title: 'Zahlungsanbieter wechseln', creator: user, custom_attributes: { 'status' => 'Offen' })
  end
  let!(:neighbour) { create(:ticket, project: project, title: 'Warenkorb aufraeumen', creator: user, custom_attributes: { 'status' => 'Offen' }) }

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane_path(of = ticket, **params)
    organisation_project_tickets_path(organisation, of.project, ticket_id: of.id, **params)
  end

  def label(count)
    I18n.t("#{rs}.waiting_mark", count: count)
  end

  # A full page load resets window; a Turbo stream keeps it.
  def mark_page
    page.execute_script('window.__waitingPageMark = true')
  end

  def same_page?
    page.evaluate_script('window.__waitingPageMark === true')
  end

  def open_modal_from_menu(scope = '#ticket-header')
    within(scope) do
      find(:button, title: I18n.t('views.organisations.tickets.ticket_header_show.more_actions')).click
      click_link I18n.t("#{rs}.menu_link")
    end
    expect(page).to have_css('[role="dialog"]')
  end

  def link_blocker
    open_modal_from_menu
    within('[role="dialog"]') do
      select I18n.t("#{rs}.kinds.blocked_by"), from: I18n.t("#{rs}.modal.kind")
      fill_in I18n.t("#{rs}.modal.ticket"), with: 'Zahlungs'
      find('[role="option"]', text: blocker.display_title).click
      click_button I18n.t("#{rs}.modal.submit")
    end
    expect(page).to have_no_css('[role="dialog"]')
  end

  def remove_blocker
    within("#ticket-relations-#{ticket.id}") do
      accept_confirm { find("button[aria-label='#{I18n.t("#{rs}.remove")}']").click }
    end
    expect(page).to have_no_css("#ticket-relations-#{ticket.id} li")
  end

  # The trigger is in the page before its Stimulus controller has connected, and a click in
  # between is lost (measured in the review of #949; column_picker_spec fails locally the same
  # way). So wait for the controller itself, then click once.
  def open_column_picker
    expect(page).to have_css('table[data-fit]', wait: 5)
    wait_for_stimulus('[data-controller~="column-picker"]', 'column-picker')
    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker', visible: :visible, wait: 5)
  end

  def cell_css(of = ticket)
    "#tickets_list_frame tr[data-ticket-id='#{of.id}'] td[data-column='waiting']"
  end

  describe 'the column in the table' do
    it 'is chosen in the picker, follows a relation made beside it, and drops a done blocker on reload' do
      visit lane_path
      expect(page).to have_css("#tickets_list_frame tr[data-ticket-id='#{ticket.id}']")

      open_column_picker
      find('#column-picker li[data-key="waiting"] label').click
      expect(page).to have_css("#tickets_list_frame th[data-column='waiting']", wait: 5)
      find('[data-column-picker-trigger]').click
      expect(page).to have_no_css('#column-picker', visible: :visible, wait: 5)
      expect(find(cell_css).text.strip).to eq('')
      mark_page

      # Linked in the lane: the open ticket's own row gets the hourglass, no page change.
      link_blocker
      within(cell_css) do
        expect(page).to have_css(%([role="img"][title="#{label(1)}"]))
        expect(page).to have_text('1')
      end
      expect(find(cell_css(neighbour)).text.strip).to eq('')
      expect(same_page?).to be(true)

      # Removed again: the cell empties.
      remove_blocker
      expect(page).to have_no_css("#{cell_css} [role='img']")
      expect(same_page?).to be(true)

      # Linked again, the blocker done elsewhere: the row keeps the sign until the list reloads.
      link_blocker
      expect(page).to have_css("#{cell_css} [role='img']")
      blocker.update!(custom_attributes: { 'status' => 'Erledigt' })
      expect(page).to have_css("#{cell_css} [role='img']")
      visit lane_path
      expect(page).to have_css(cell_css)
      expect(page).to have_no_css("#{cell_css} [role='img']")
    end
  end

  # At 1440 px with the lane open the table keeps number and title only (data-fit 0): the cell
  # is there but has no width. A pinned column shows its value under the title instead, and the
  # help says so (review of #949).
  describe 'with the lane open on a laptop' do
    let(:table_columns) { %w[number title assignees created_at waiting] }

    before do
      ViewConfiguration.find_by!(user: user, project: project).update!(pinned_columns: %w[waiting])
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride',
                                      width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    end

    after { page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride') }

    it 'shows the pinned state under the title once a relation is made beside it' do
      visit lane_path
      item = "#tickets_list_frame tr[data-ticket-id='#{ticket.id}'] .ticket-meta__item[data-meta-column='waiting']"
      expect(page).to have_css('.layout.two-column:not(.hide-content)', wait: 5)
      expect(page).to have_no_css(item, visible: :visible)

      link_blocker

      expect(page).to have_css(item, visible: :visible, text: I18n.t('views.organisations.tickets.tickets_results.waiting_meta', count: 1))
      expect(page).to have_no_css("#tickets_list_frame td[data-column='waiting']", visible: :visible)
    end
  end

  describe 'on the board' do
    let(:view_mode) { 'kanban' }

    it 'shows the sign on the card of a waiting ticket and on the open card once linked' do
      TicketRelation.create!(source_ticket: blocker, target_ticket: neighbour, relation_type: :blocks)

      visit lane_path
      expect(page).to have_css("#kanban-card-#{neighbour.id} .ticket-waiting-mark[title='#{label(1)}']")
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
      expect(page).to have_no_css("#kanban-card-#{ticket.id} .ticket-waiting-mark")
      mark_page

      link_blocker
      expect(page).to have_css("#kanban-card-#{ticket.id} .ticket-waiting-mark[aria-label='#{label(1)}']")
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
      expect(same_page?).to be(true)

      remove_blocker
      expect(page).to have_no_css("#kanban-card-#{ticket.id} .ticket-waiting-mark")
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
    end
  end

  describe 'on a phone' do
    before do
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride',
                                      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    end

    after { page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride') }

    it 'shows the sign next to the number, and nothing spills over the edge' do
      TicketRelation.create!(source_ticket: blocker, target_ticket: ticket, relation_type: :blocks)

      visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
      row = find(".mobile-ticket-row[data-ticket-id='#{ticket.id}']")
      within(row) do
        meta = find('.mobile-ticket-meta')
        expect(meta).to have_css('.ticket-waiting-mark', visible: :visible)
        expect(meta.find('.ticket-waiting-mark')['aria-label']).to eq(label(1))
        number, mark = meta.all(':scope > *').first(2)
        expect(number.text).to eq("##{ticket.number}")
        expect(mark[:class]).to include('ticket-waiting-mark')
      end
      expect(page).to have_no_css(".mobile-ticket-row[data-ticket-id='#{neighbour.id}'] .ticket-waiting-mark")
      overflow = page.evaluate_script('document.documentElement.scrollWidth > window.innerWidth')
      expect(overflow).to be(false)
    end
  end
end
