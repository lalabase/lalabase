# frozen_string_literal: true

require 'rails_helper'

# What: The in-app help end-to-end (D6): sidebar entry → help start page →
#       live search → open a hit; the keyboard-only combobox flow (D10-KB —
#       arrow to select, Enter to open, keep arrowing after opening); plus the
#       mobile branch (DT7 — the tree view must stay reachable below the
#       breakpoint).
# Type: System spec (real browser) — the debounced search (Stimulus → Turbo
#       frame swap), the keyboard navigation (aria-activedescendant, focus
#       restore across a _top navigation) and the viewport switching need JS;
#       everything else about the help is covered in the request specs.
#       The pages are the two of the recorded example catalogue
#       (spec/fixtures/docs_catalogue), not the handbook, which lives in
#       gboyke/lalabase-documentation since D5.
# Why:  The flow crosses four moving parts (sidebar link, index redirect,
#       frame-search controller, _top link out of the frame) that only a
#       browser exercises together. The keyboard path additionally spans a full
#       page navigation with a sessionStorage handoff, so only a browser proves
#       focus lands back in the field.
RSpec.describe 'In-App-Hilfe (System)', type: :system do
  let(:first_page) { 'Erste Beispielseite' }
  let(:second_page) { 'Zweite Beispielseite' }
  let(:search_term) { 'Beispielseite' } # in both titles

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    login_as(user, scope: :user)
  end

  it 'führt vom Sidebar-Einstieg über die Suche zum Treffer (D6)' do
    visit organisation_root_path(organisation_id: organisation.id)

    click_link I18n.t('navigation.help', locale: :de)

    # The index redirects to the first guides page.
    expect(page).to have_css('#help-page')
    expect(page).to have_content(first_page)

    # Live search: debounced input swaps the Turbo frame with the hit list.
    find("input[placeholder='#{I18n.t('views.organisations.help.search.placeholder', locale: :de)}']")
      .fill_in(with: 'Zweite')

    within('turbo-frame#help-search-results') do
      expect(page).to have_link(second_page)
      click_link second_page
    end

    # The hit navigates the PAGE (_top), not the result frame.
    expect(page).to have_css('.help-prose h1', text: second_page)
  end

  it 'navigiert die Trefferliste komplett per Tastatur (D10-KB)' do
    visit organisation_root_path(organisation_id: organisation.id)
    click_link I18n.t('navigation.help', locale: :de)
    expect(page).to have_css('#help-page')

    input = find("input[role='combobox']")
    input.fill_in(with: search_term)

    # The term hits both example pages — we need at least two cards to test
    # both the arrow movement and opening a *different* hit afterwards.
    # Wait for the answer to the WHOLE term: a debounce can fire on a prefix while
    # typing, and the later swap resets any selection made on the earlier list.
    expect(page).to have_css("turbo-frame#help-search-results[complete][src*='q=#{search_term}&']")
    expect(page).to have_css('turbo-frame#help-search-results [role="option"]', minimum: 2)
    options = all('turbo-frame#help-search-results [role="option"]')
    title_first = options[0].first('span').text
    title_second = options[1].first('span').text
    expect(title_first).not_to eq(title_second)

    # Arrow-down from the field selects the first card (visual + aria wiring), the
    # DOM focus never leaves the input (combobox pattern).
    input.send_keys(:down)
    first_option = find('turbo-frame#help-search-results [role="option"]', match: :first)
    expect(first_option['aria-selected']).to eq('true')
    expect(input['aria-activedescendant']).to eq(first_option['id'])

    # Down moves to the second card, up returns to the first.
    input.send_keys(:down)
    expect(all('turbo-frame#help-search-results [role="option"]')[1]['aria-selected']).to eq('true')
    expect(all('turbo-frame#help-search-results [role="option"]')[0]['aria-selected']).to be_nil
    input.send_keys(:up)
    expect(find('turbo-frame#help-search-results [role="option"]', match: :first)['aria-selected']).to eq('true')

    # Escape drops the selection but keeps the term and the field untouched.
    input.send_keys(:escape)
    expect(page).to have_no_css('turbo-frame#help-search-results [role="option"][aria-selected="true"]')
    expect(input.value).to eq(search_term)

    # Re-select the first card and open it: Enter behaves exactly like a click
    # (whole page navigates via _top).
    input.send_keys(:down)
    input.send_keys(:enter)
    expect(page).to have_css('.help-prose h1', text: title_first)

    # Resume: the list survived, the opened card is reselected AND aria-current, and the
    # DOM focus is back in the field — so the user keeps arrowing without a click.
    expect(page).to have_css(
      'turbo-frame#help-search-results [role="option"][aria-selected="true"][aria-current="page"]'
    )
    expect(page.evaluate_script("document.activeElement && document.activeElement.getAttribute('role')")).to eq('combobox')

    # Down + Enter now opens a DIFFERENT hit, no mouse involved.
    reopened_input = find("input[role='combobox']")
    reopened_input.send_keys(:down)
    reopened_input.send_keys(:enter)
    expect(page).to have_css('.help-prose h1', text: title_second)
  end

  it 'zeigt mobil die Baum-Navigation und öffnet eine Seite (DT7)' do
    page.current_window.resize_to(390, 844)

    visit help_path(viewport: 'mobile')

    # Tree view instead of a redirect: the pages of both sections are listed.
    # (Section captions are CSS-uppercased — assert on the links, not the text.)
    expect(page).to have_link(first_page)
    expect(page).to have_link(second_page)
    click_link second_page

    expect(page).to have_css('.help-prose h1', text: second_page)

    # The back link keeps the mobile viewport and returns to the tree.
    click_link I18n.t('views.organisations.help.show.back_to_tree', locale: :de)
    expect(page).to have_content(first_page)
    expect(page).to have_content(second_page)
  ensure
    page.current_window.resize_to(1400, 900)
  end
end
