# frozen_string_literal: true

require 'rails_helper'

# What: the bar of the inbox, Personen and Glossar (.list-tab-bar) keeps one
#       row while its tools fit beside the tabs; where they do not, the tools
#       move to a line above the tabs, and the tabs keep the whole row on the
#       divider (tabs that are wider than the row by themselves scroll sideways).
# Why:  until 2026-11-11 the row never wrapped: on a phone the inbox's two
#       selects took the room and cut its tabs down to "Alle Ung", and the
#       glossary's would have done the same. Measured in a browser, because
#       only the layout shows what fits.
RSpec.describe 'List tab bar on a narrow row', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:person, organisation: organisation, name: 'Berta Erste')
    create(:glossary_term, organisation: organisation, term: 'Zorbelstein')
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # A phone for one example. Its width comes from the device metrics, NOT from the
  # window: a Chrome window on a Mac is never narrower than 500 px, so
  # `resize_to(400, ...)` measured a 500 px page there and a 400 px page in CI (with a
  # scrollbar taking 15 of them). From 2026-11-11, the day this spec was written, the
  # phone example was green on every Mac and red on every PR.
  def on_a_phone(width)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
    yield
  ensure
    # The browser outlives the example: without this every later spec runs on a phone.
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end

  # Where the tab strip and the tools stand in the bar, in whole pixels: the room
  # the bar has for a row (row), how wide the strip is (strip), how wide its tabs
  # are together (tabs_need), and how much of them is cut (cut).
  def geometry
    expect(page).to have_css('.list-tab-bar [role="tablist"]')
    page.evaluate_script(<<~JS)
      (function () {
        var bar = document.querySelector('.list-tab-bar');
        var tabs = bar.querySelector('[role="tablist"]');
        var tools = bar.querySelector('.list-tab-bar__tools') || bar.querySelector('[data-fb-search]');
        var style = getComputedStyle(bar);
        var b = bar.getBoundingClientRect(), t = tabs.getBoundingClientRect(), o = tools.getBoundingClientRect();
        return { row: Math.round(bar.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)),
                 strip: tabs.clientWidth, tabs_need: tabs.scrollWidth, cut: tabs.scrollWidth - tabs.clientWidth,
                 overflow_x: getComputedStyle(tabs).overflowX,
                 tabs_top: Math.round(t.top), tabs_bottom: Math.round(t.bottom),
                 tools_top: Math.round(o.top), tools_bottom: Math.round(o.bottom), bar_bottom: Math.round(b.bottom),
                 page_overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
      })()
    JS
  end

  # The tools stand on a line of their own above the tabs and take no room from
  # them: the strip is as wide as its tabs, or as the whole row where the tabs
  # alone are wider. Then, and only then, the strip scrolls sideways
  # (.list-tab-bar__tabs, rule 7: moved, never shrunk).
  def expect_tools_above_tabs_that_keep_the_row(name)
    measured = geometry
    expect(measured['tools_bottom']).to be <= measured['tabs_top'], "#{name}: the tools do not stand above the tabs: #{measured.inspect}"
    expect(measured['strip']).to be >= [measured['tabs_need'], measured['row']].min - 1,
                                 "#{name}: the tools take room from the tabs: #{measured.inspect}"
    expect(measured['overflow_x']).to eq('auto'), "#{name}: cut tabs could not be reached: #{measured.inspect}" if measured['cut'].positive?
    expect((measured['bar_bottom'] - measured['tabs_bottom']).abs).to be <= 1, "#{name}: the tabs left the divider: #{measured.inspect}"
    expect(measured['page_overflow']).to be <= 0, "#{name}: the page scrolls sideways: #{measured.inspect}"
    measured
  end

  it 'moves the tools above the tabs on a phone, and the tabs keep the whole row: the inbox and the glossary' do
    on_a_phone(390) do
      visit organisation_notifications_path(organisation, viewport: 'mobile')
      inbox = expect_tools_above_tabs_that_keep_the_row('Inbox')
      # The case the wrap was built for: the inbox's two selects cut its tabs down to
      # "Alle Ung". Its tabs fit a phone, so none of them may be cut.
      expect(inbox['cut']).to be <= 0, "Inbox: the tabs are cut: #{inbox.inspect}"

      visit organisation_glossary_terms_path(organisation, viewport: 'mobile')
      # The glossary's four tabs with their counts are wider than a 390 px phone has
      # room for (measured 2026-11-12: 382 px of tabs in a row of 358). That is no
      # failure: they keep the whole row and the last one is reached by a swipe.
      expect_tools_above_tabs_that_keep_the_row('Glossar')
    end
  end

  it 'keeps one row where the tools fit: the glossary and Personen on a desk' do
    page.driver.browser.manage.window.resize_to(1400, 900)

    [organisation_glossary_terms_path(organisation), organisation_people_path(organisation)].each do |path|
      visit path
      measured = geometry
      expect(measured['tools_bottom']).to be > measured['tabs_top'], "#{path}: the tools left the tabs' row: #{measured.inspect}"
      expect(measured['cut']).to be <= 0, "#{path}: the tabs are cut: #{measured.inspect}"
    end
  end
end
