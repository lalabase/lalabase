# frozen_string_literal: true

require 'rails_helper'

# With real clicks: the header of the sidebar with the switcher (common/_sidebar_header,
# Belegungstabelle F49). What only a browser shows: where details_autoclose places the menu
# (against the aside, also on the level, where no scroll column of an organisation stands
# above it), that it floats with a soft shadow, and every way of closing it.
RSpec.describe 'The header of the sidebar with the switcher (System)', type: :system do
  let(:user) { create(:user, email: 'lena@example.com', language_preference: 'de') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  before do
    # CSS on: the box and the shadow are what this spec measures.
    driven_by :selenium_chrome_headless_full
    Prosopite.pause
    [north, south].each do |org|
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
      end
    end
    ActsAsTenant.current_tenant = nil
    login_as(user, scope: :user)
    page.driver.browser.manage.window.resize_to(1280, 900)
  end

  after { Prosopite.resume }

  def summary
    find('#sidebar [data-sidebar-header] details > summary')
  end

  def menu_selector
    '#sidebar [data-sidebar-header] ul[data-details-autoclose-target="panel"]'
  end

  def open_menu
    summary.click
    expect(page).to have_css('#sidebar [data-sidebar-header] details[open]')
    # Placed means: details_autoclose has measured it and shows it.
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("getComputedStyle(document.querySelector('#{menu_selector}')).opacity") == '1'
    end
  end

  def box(selector)
    page.evaluate_script(<<~JS, selector).transform_keys(&:to_sym)
      (() => {
        const r = document.querySelector(arguments[0]).getBoundingClientRect()
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }
      })()
    JS
  end

  def expect_menu_inside_aside
    menu = box(menu_selector)
    aside = box('#sidebar')
    expect(menu[:left]).to be >= aside[:left]
    expect(menu[:right]).to be <= aside[:right]
    expect(menu[:top]).to be >= aside[:top]
    expect(menu[:bottom]).to be <= aside[:bottom]
  end

  # The blur of every visible layer of the computed shadow ("rgba(...) x y blur spread").
  # Tailwind puts two transparent ring layers in front; they draw nothing and are left out.
  def shadow_blurs
    shadow = page.evaluate_script("getComputedStyle(document.querySelector('#{menu_selector}')).boxShadow")
    layers = shadow.split(/,(?![^(]*\))/).reject { |layer| layer.match?(/rgba\([^)]*,\s*0\)|transparent/) }
    layers.map { |layer| layer.scan(/(-?\d+(?:\.\d+)?)px/).flatten.map(&:to_f)[2] }
  end

  { 'on the cockpit' => -> { select_organisation_path },
    'inside an organisation' => -> { organisation_root_path(organisation_id: north.id) } }.each do |where, path|
    it "opens #{where} inside the aside, with a soft shadow" do
      visit instance_exec(&path)
      page.execute_script("localStorage.setItem('lb-theme', 'light')")
      visit instance_exec(&path)

      open_menu

      expect_menu_inside_aside
      expect(shadow_blurs).to all(be > 0)
      expect(shadow_blurs).not_to be_empty
    end
  end

  it 'closes on Escape and on a click outside' do
    visit select_organisation_path
    open_menu

    page.send_keys(:escape)
    expect(page).to have_no_css('#sidebar [data-sidebar-header] details[open]')

    open_menu
    find('main h1', match: :first).click
    expect(page).to have_no_css('#sidebar [data-sidebar-header] details[open]')
  end

  it 'opens the dashboard of the organisation clicked in the menu' do
    visit select_organisation_path
    open_menu

    within(menu_selector) { click_link 'Sued AG' }

    expect(page).to have_current_path(/\A#{Regexp.escape(organisation_root_path(organisation_id: south.id))}/)
    expect(page).to have_css('#sidebar [data-sidebar-header] summary', text: 'Sued AG')
  end

  # Review PR 2 round 1: the rows are Turbo links now, so the page comes back from Turbo's
  # snapshot. The menu must not stand open in it (F49: a change of page closes it).
  it 'shows the menu closed after going back to the page it was opened on' do
    visit organisation_root_path(organisation_id: north.id)
    open_menu
    within(menu_selector) { click_link 'Sued AG' }
    expect(page).to have_css('#sidebar [data-sidebar-header] summary', text: 'Sued AG')

    page.go_back

    expect(page).to have_css('#sidebar [data-sidebar-header] summary', text: 'Nord GmbH')
    expect(page).to have_no_css('#sidebar [data-sidebar-header] details[open]')
  end

  it 'opens the inbox above the organisations from "Alle Organisationen" inside an organisation' do
    visit organisation_root_path(organisation_id: north.id)
    open_menu

    within(menu_selector) { click_link I18n.t('navigation.all_organisations') }

    expect(page).to have_current_path(all_inboxes_path)
    expect(page).to have_css('#sidebar [data-sidebar-header] summary', text: I18n.t('navigation.all_organisations'))
  end
end
