# frozen_string_literal: true

require 'rails_helper'

# With real clicks: the account layer of the sidebar (common/_account_layer, F47,
# sidebar_layer_controller). A click on the reader's name raises the pages of "Mein
# Konto" from the foot of the sidebar up to the logo, and the page behind stays.
#
# What only a browser shows: that the layer covers the sidebar between logo and name and
# nothing else, that the page does not change until an entry is chosen, that what is
# covered cannot be reached by the keyboard, and every way of closing it again.
RSpec.describe 'The account layer of the sidebar', type: :system do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH') }
  let(:lena) { create(:user, first_name: 'Lena', last_name: 'Beispiel', email: 'lena@example.com', language_preference: 'de') }
  let(:start) { organisation_root_path(organisation_id: organisation.id) }

  before do
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: lena, organisation: organisation, role: create(:admin_role, organisation: organisation),
                          active: true)
    end
    sign_in lena
    page.driver.browser.manage.window.resize_to(1200, 800)
    visit start
  end

  after { Prosopite.resume }

  def name_row
    find('#sidebar .sidebar-layer__trigger')
  end

  def layer
    find('#account-layer', visible: :all)
  end

  # Open means: standing in its place, not on its way there.
  def expect_layer_open
    expect(page).to have_css('#account-layer[data-state="open"]')
    expect(page).to have_css('#sidebar .sidebar-layer__trigger[aria-expanded="true"]')
    Timeout.timeout(Capybara.default_max_wait_time) { sleep 0.05 until box('#account-layer')[:top] == stage[:top] }
  end

  def expect_layer_closed
    expect(page).to have_css('#account-layer[hidden]', visible: :all)
    expect(page).to have_css('#sidebar .sidebar-layer__trigger[aria-expanded="false"]')
  end

  def box(selector)
    page.evaluate_script(<<~JS, selector).transform_keys(&:to_sym)
      (() => {
        const rect = document.querySelector(arguments[0]).getBoundingClientRect()
        return { top: Math.round(rect.top), bottom: Math.round(rect.bottom), left: Math.round(rect.left), right: Math.round(rect.right) }
      })()
    JS
  end

  # The grid cell the layer shares with what it covers.
  def stage
    box('#sidebar [data-sidebar-layer-target="covered"]')
  end

  it 'waits hidden, and the name is a button that says so' do
    expect_layer_closed
    expect(name_row['role']).to eq('button')
    expect(page.evaluate_script("document.querySelector('#sidebar [data-sidebar-layer-target=\"covered\"]').inert")).to be(false)
  end

  it 'rises over the sidebar from the name up to the logo, and leaves the page alone' do
    name_row.click
    expect_layer_open

    panel = box('#account-layer')
    expect(panel).to eq(stage)
    expect(panel[:top]).to be >= box('#sidebar [data-brand-link]')[:bottom]
    expect(panel[:bottom]).to be <= box('#sidebar .sidebar-layer__trigger')[:top]
    expect(panel[:right]).to be <= box('#sidebar')[:right]

    expect(page).to have_current_path(start)
    within(layer) do
      %w[all_organisations profile billing_accounts data_export settings_api_tokens preferences logout].each do |key|
        expect(page).to have_link(I18n.t("navigation.#{key}"))
      end
    end
  end

  # The covered navigation is still in the page. A reader must not be able to press
  # what they cannot see, with the mouse or with the keyboard.
  it 'takes what it covers out of reach, and gives the focus to its first entry' do
    name_row.click
    expect_layer_open

    expect(page.evaluate_script("document.querySelector('#sidebar [data-sidebar-layer-target=\"covered\"]').inert")).to be(true)
    expect(page.evaluate_script('document.activeElement.textContent.trim()')).to eq(I18n.t('navigation.all_organisations'))
    on_top = page.evaluate_script(<<~JS)
      (() => {
        const rect = document.querySelector('#sidebar [data-sidebar-layer-target="covered"]').getBoundingClientRect()
        const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
        return Boolean(hit && hit.closest('#account-layer'))
      })()
    JS
    expect(on_top).to be(true)
  end

  it 'closes on the name again' do
    name_row.click
    expect_layer_open

    name_row.click

    expect_layer_closed
    expect(page.evaluate_script("document.querySelector('#sidebar [data-sidebar-layer-target=\"covered\"]').inert")).to be(false)
    expect(page).to have_current_path(start)
  end

  it 'closes on its cross' do
    name_row.click
    expect_layer_open

    within(layer) { find("button[aria-label='#{I18n.t('views.common.close')}']").click }

    expect_layer_closed
  end

  it 'closes on Escape and gives the focus back to the name' do
    name_row.click
    expect_layer_open

    page.send_keys(:escape)

    expect_layer_closed
    expect(page.evaluate_script("document.activeElement.classList.contains('sidebar-layer__trigger')")).to be(true)
  end

  it 'closes on a press on the page behind it' do
    name_row.click
    expect_layer_open

    find('main h1', match: :first).click

    expect_layer_closed
    expect(page).to have_current_path(start)
  end

  it 'leads to an account page, whose sidebar shows the same list' do
    name_row.click
    expect_layer_open
    entries = layer.all('[data-account-nav-list] a').map(&:text)

    within(layer) { click_link I18n.t('navigation.preferences') }

    expect(page).to have_current_path(edit_user_preferences_path)
    expect(page).to have_css('main h1', exact_text: I18n.t('navigation.preferences'))
    expect(page).to have_no_css('#account-layer', visible: :all)
    expect(all('#sidebar [data-account-nav-list] a').map(&:text)).to eq(entries)
  end

  it 'is closed again when the reader comes back to the page' do
    name_row.click
    expect_layer_open
    within(layer) { click_link I18n.t('navigation.preferences') }
    expect(page).to have_current_path(edit_user_preferences_path)

    page.go_back

    expect(page).to have_current_path(start)
    expect_layer_closed
  end

  # Signing out from the layer is held by the request spec (the link, its method): the
  # test host answers the sign-out with a redirect to another origin, which no browser
  # follows, so a click here proves nothing about the layer.
end
