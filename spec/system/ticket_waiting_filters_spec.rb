# frozen_string_literal: true

require 'rails_helper'

# The two waiting filters in the bar, clicked for real (doc/ticket_relations_plan.md,
# revision 4, §9): pick "Wartet" behind "+ Filter", tick its one option, the
# pill says "ja" and the list narrows; switch to "ist nicht", the pill says "nein" and the list
# turns round; save it as a view, open the view again, and the same pill with the same operator
# is back, editable, not an expert rule. The bar is JavaScript over the address, so only a
# browser sees the round trip; the request and service specs hold the rest.
RSpec.describe 'Waiting filters in the filter bar', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Kundenportal') }
  let(:waiting_label) { I18n.t('views.organisations.tickets.index.filter_waiting') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                        active: true)
    create(:ticket_attribute_definition,
           project: project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
           ] })
    ViewConfiguration.create!(user: user, project: project, organisation: organisation, view_type: 'tickets',
                              view_mode: 'table', table_columns: %w[number title], header_columns: %w[assignees],
                              list_columns: { 'cells' => [], 'metadata' => [] })
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:waiter) { create(:ticket, project: project, title: 'Checkout bricht ab', creator: user, custom_attributes: { 'status' => 'Offen' }) }
  let!(:blocker) { create(:ticket, project: project, title: 'Zahlungsanbieter wechseln', creator: user, custom_attributes: { 'status' => 'Offen' }) }
  let!(:plain) { create(:ticket, project: project, title: 'Warenkorb aufraeumen', creator: user, custom_attributes: { 'status' => 'Offen' }) }

  before { TicketRelation.create!(source_ticket: blocker, target_ticket: waiter, relation_type: :blocks) }

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # The pill says the category and, in its value tile, "ja" or "nein".
  def expect_pill(word)
    expect(page).to have_css('[data-condition="waiting"] [data-value-tile]', exact_text: word, wait: 5)
    expect(page).to have_css('[data-condition="waiting"]', text: waiting_label)
  end

  def expect_rows(*tickets)
    tickets.each { |each_ticket| expect(page).to have_css("tr[data-ticket-id='#{each_ticket.id}']", wait: 5) }
    expect(page).to have_css('tr[data-ticket-id]', count: tickets.size, wait: 5)
  end

  it 'filters, turns round, saves as a view and reads the view back as the same pill' do
    visit organisation_project_tickets_path(organisation, project)
    expect_rows(waiter, blocker, plain)

    find('[data-filter-bar-target="filterButton"]').click
    find('[role="menuitem"][data-category="waiting"]', text: waiting_label).click
    within('[data-filter-bar-target="valueMenu"]') { find('input[type="checkbox"][data-filter-value="true"]').click }

    expect_pill('ja')
    expect_rows(waiter)

    within('[data-filter-bar-target="valueMenu"]') do
      find('[data-action="click->filter-bar#toggleOperatorDropdown"]').click
      find('[data-operator="not"]').click
    end

    expect_pill('nein')
    expect_rows(blocker, plain)

    # Escape to the focused element, not to body: Selenium clicks an element before it types
    # into it, and a click on the page could open a ticket lane. One layer per key.
    page.send_keys(:escape)
    expect(page).to have_css('[data-filter-bar-target="valueMenu"].hidden', visible: :all, wait: 5)
    page.send_keys(:escape)
    expect(page).to have_css('[data-filter-bar-target="filterMenu"].hidden', visible: :all, wait: 5)
    within('[data-filter-bar-target="saveRow"]') { click_on 'Als Ansicht sichern' }
    field = find('input[name="smart_folder_name"]', wait: 3)
    field.set('Wartet nicht')
    field.send_keys(:enter)

    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Wartet nicht', wait: 5)
    rule = SmartFolder.find_by!(name: 'Wartet nicht').smart_folder_rule_groups.sole.smart_folder_rules.sole
    expect([rule.field, rule.operator, rule.value]).to eq(['waiting', SmartFolders::Operators::IS_NOT, 'true'])

    # Away to the base list, back through the tab: a fresh load of the saved view.
    visit organisation_project_tickets_path(organisation, project)
    expect_rows(waiter, blocker, plain)
    find('a[role="tab"]', text: 'Wartet nicht').click

    expect(page).to have_css('[data-fb-prose]', text: 'die nicht auf ein offenes Ticket warten', wait: 5)
    expect_rows(blocker, plain)
    click_on 'ändern'
    expect(page).to have_css('[data-condition="waiting"] [data-chevron]', wait: 5)
    expect_pill('nein')
    expect(page).to have_no_css('[data-complex-rule]')
    expect(page).not_to have_css('[data-filter-bar-target="saveRow"]', visible: :visible)
  end
end
