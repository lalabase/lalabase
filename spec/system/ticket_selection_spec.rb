# frozen_string_literal: true

require 'rails_helper'

# The browser contract for ticket selection. The pure model specs pin ranges and
# address rules; these examples pin the Stimulus/Turbo seam that unit tests cannot
# see: row-level stream replacements and the three mutually exclusive bar states.
RSpec.describe 'Ticket list selection', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:tickets) do
    ActsAsTenant.with_tenant(organisation) do
      create_list(:ticket, 2, project: project, organisation: organisation, creator: user)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    visit organisation_project_tickets_path(organisation, project)
    expect(page).to have_css('[data-controller~="ticket-selection"]')
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'restores a selected replacement row and forgets a removed row' do
    ticket = tickets.first
    row_selector = "tr[data-ticket-id='#{ticket.id}']"
    box_selector = "#{row_selector} input[data-ticket-selection-target='box']"

    page.execute_script("window.__ticketRowBeforeSelection = document.querySelector(#{row_selector.to_json}).outerHTML")
    find(box_selector, visible: :all).click
    expect(page).to have_css("#{row_selector}.selection-ticked #{box_selector.split.last}:checked")

    page.execute_script(<<~JS)
      document.querySelector(#{row_selector.to_json}).outerHTML = window.__ticketRowBeforeSelection
    JS
    expect(page).to have_css("#{row_selector}.selection-ticked input[data-ticket-selection-target='box']:checked")

    page.execute_script("document.querySelector(#{row_selector.to_json}).remove()")
    expect(page).to have_no_css('[data-ticket-selection-target="row"]', visible: true)
  end

  it 'keeps normalized addresses distinct and renders one bar state at a time' do
    normalized = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("ticket_selection")
        .then(({ normalizeAddress }) => done([
          normalizeAddress("?search=foo%26sort%5Bcolumn%5D%3Dtitle"),
          normalizeAddress("?search=foo&sort[column]=title")
        ]))
        .catch((error) => done({ error: error.message }))
    JS
    expect(normalized).to be_an(Array)
    expect(normalized.first).not_to eq(normalized.last)

    box = "input[data-ticket-selection-target='box'][value='#{tickets.last.id}']"
    find(box, visible: :all).click
    page.execute_script(<<~JS)
      window.history.replaceState({}, "", "?search=changed")
      document.getElementById("tickets_list_frame")
        .dispatchEvent(new CustomEvent("turbo:frame-load", { bubbles: true }))
    JS

    expect(page).to have_css('[data-ticket-selection-target="note"]', visible: true)
    expect(page).to have_css('#tickets_list_frame_sentence[hidden]', visible: :all)
    expect(page).to have_no_css('[data-ticket-selection-target="row"]', visible: true)

    find(box, visible: :all).click
    expect(page).to have_css('[data-ticket-selection-target="row"]', visible: true)
    expect(page).to have_no_css('[data-ticket-selection-target="note"]', visible: true)
    expect(page).to have_css('#tickets_list_frame_sentence[hidden]', visible: :all)
  end

  it 'keeps the selection when the page size changes without an open ticket' do
    ticket = tickets.first
    box = "input[data-ticket-selection-target='box'][value='#{ticket.id}']"
    find(box, visible: :all).click

    pagination = find('[data-controller="neo-pagination"]', match: :first)
    pagination.find('option[value*="items=10"]', visible: :all).select_option

    expect(page).to have_css("tr[data-ticket-id='#{ticket.id}'].selection-ticked #{box}:checked")
    expect(page).to have_css('[data-ticket-selection-target="row"]', visible: true)
  end
end
