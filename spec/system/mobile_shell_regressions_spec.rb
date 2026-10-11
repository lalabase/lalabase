# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Mobile shell regressions', type: :system do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    create(:ticket, project: project, title: 'Mobiles Ticket')
    sign_in user
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
  end

  after do
    page.driver.browser.execute_cdp('Emulation.setEmulatedMedia', media: '')
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def scroll_document_to(position)
    page.evaluate_async_script(<<~JS, position)
      const y = arguments[0], done = arguments[1]
      if (window.scrollY === y) { done(); return }
      window.addEventListener('scroll', () => requestAnimationFrame(() => done()), { once: true })
      window.scrollTo(0, y)
    JS
  end

  def swipe_background
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: true)
    page.driver.browser.execute_cdp('Input.synthesizeScrollGesture', x: 195, y: 90,
                                                                     yDistance: -350, speed: 800, gestureSourceType: 'touch')
    page.evaluate_async_script('requestAnimationFrame(() => requestAnimationFrame(arguments[0]))')
  end

  it 'keeps sufficient contrast for the primary action and Inbox count in Dark' do
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    page.execute_script("window.__lbTheme.set('dark')")
    contrast = page.evaluate_script(<<~JS)
      (() => {
        const luminance = color => {
          const rgb = color.match(/[\\d.]+/g).slice(0, 3).map(v => Number(v) / 255)
            .map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4)
          return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722
        }
        return ['.mobile-primary', '.mobile-inbox-count'].map(selector => {
          const style = getComputedStyle(document.querySelector(selector))
          const a = luminance(style.color), b = luminance(style.backgroundColor)
          return (Math.max(a, b) + .05) / (Math.min(a, b) + .05)
        })
      })()
    JS
    expect(contrast).to all(be >= 4.5)
  end

  it 'allows the document to grow when printing an organisation page' do
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    page.driver.browser.execute_cdp('Emulation.setEmulatedMedia', media: 'print')
    expect(page).to have_no_css('.mobile-bottom-bar', visible: true)
    expect(page.evaluate_script('getComputedStyle(document.body).overflowY')).not_to eq('hidden')
    expect(page.evaluate_script('getComputedStyle(document.querySelector(".mobile-app-screen > main")).overflowY')).not_to eq('auto')
  end

  it 'restores document scrolling after visiting More and going back' do
    create_list(:ticket, 20, project: project)
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile', items: 50)
    expect(page).to have_css('.mobile-ticket-title', count: 21)
    # Turbo records the native scroll event, not the synchronous scrollY write.
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      window.addEventListener('scroll', () => requestAnimationFrame(() => done()), { once: true })
      window.scrollTo(0, 400)
    JS
    expect(page).to have_css('body') { |body| body.evaluate_script('window.scrollY') == 400 }
    within('.mobile-bottom-links') { click_link I18n.t('mobile.more') }
    expect(page).to have_css('.mobile-destination')
    # The destination is visible before Turbo finishes scrolling and storing history.
    expect(page).to have_no_css('html[aria-busy="true"]')
    page.go_back
    expect(page).to have_css('.mobile-ticket-title', count: 21)
    expect(page).to have_css('body') { |body| body.evaluate_script('window.scrollY') == 400 }
  end

  %i[projects editor assistant].each do |sheet|
    it "locks document scrolling while the #{sheet} sheet is open" do
      organisation.update!(assistant_enabled: true)
      create(:permission, role: user.memberships.find_by!(organisation: organisation).role,
                          category: 'assistant', action: 'use_assistant', allowed: true)
      create_list(:ticket, 20, project: project)
      visit organisation_project_tickets_path(organisation, project, viewport: 'mobile', items: 50)
      expect(page).to have_css('.mobile-ticket-title', count: 21)

      scroll_document_to(400)
      scroll_document_to(0)

      case sheet
      when :projects
        find('.mobile-heading button').click
        expect(page).to have_css('dialog[open] .mobile-project-list')
      when :editor
        find('button[aria-label="Tickets auswählen"]').click
        find('.mobile-ticket-check input', match: :first).click
        find('.mobile-bottom-actions button', text: '1 bearbeiten').click
        expect(page).to have_css('dialog[open] .ticket-bulk-panel')
      when :assistant
        find('.mobile-header [data-controller="assistant-trigger"]').click
        expect(page).to have_css('#assistant_panel_body')
      end

      swipe_background
      expect(page.evaluate_script('window.scrollY')).to eq(0)

      case sheet
      when :projects then find('[data-action="mobile-shell#closeProjects"]').click
      when :editor then click_button I18n.t('mobile.back_tickets')
      when :assistant then find('#assistant_panel [data-assistant-panel-target="panel"] button[data-action="assistant-panel#close"]').click
      end
      scroll_document_to(400)
      expect(page.evaluate_script('window.scrollY')).to eq(400)
    end
  end

  it 'keeps meeting details in their desktop layout between 768 and 1024 pixels' do
    meeting = create(:meeting, project: project, organisation: organisation, creator: user, title: 'Analysebesprechung')
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 900, height: 844, deviceScaleFactor: 1, mobile: true)
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    within('.mobile-project-tabs') { click_link 'Meetings' }
    expect(page).to have_css('[data-controller="list-row"]', text: meeting.title)
    find('[data-controller="list-row"]', text: meeting.title).click
    expect(page).to have_css('#meeting_display_frame', text: meeting.title)
    expect(page).to have_no_button('Analysen')
    expect(page).to have_no_css('#meeting_analyses_lane')
  end
  it 'renders identifiable text actions with readable contrast in every theme' do
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    find('.mobile-heading button').click
    expect(page).to have_link(I18n.t('mobile.all_projects'))
    %w[light dark pop].each do |theme|
      page.execute_script('window.__lbTheme.set(arguments[0])', theme)
      colors = page.evaluate_script(<<~JS)
        (() => {
          const action = document.querySelector('dialog[open] .mobile-text-action')
          const sheet = action.closest('dialog')
          const luminance = color => {
            const rgb = color.match(/[\\d.]+/g).slice(0, 3).map(v => Number(v) / 255)
              .map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4)
            return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722
          }
          const text = getComputedStyle(action).color, background = getComputedStyle(sheet).backgroundColor
          const a = luminance(text), b = luminance(background)
          return { text, body: getComputedStyle(sheet).color, ratio: (Math.max(a, b) + .05) / (Math.min(a, b) + .05) }
        })()
      JS
      expect(colors['text']).not_to eq(colors['body'])
      expect(colors['ratio']).to be >= 4.5
    end
  end

  # The filter panels of the time list and of the billings (browser check and
  # review, 29.09.2026). Three ways they grew past a phone's edge:
  #   - the panel is a grid with a 1fr column, and a 1fr track never shrinks
  #     below its content: the search field's fixed 420px set that minimum;
  #   - a chosen value with a long name made its pill wider than the column;
  #   - an opened menu hangs from its pill and ran past the right edge, also
  #     when it grew after opening, the screen narrowed, or the drawer showed
  #     a menu that was open already.
  # 375px, the narrowest common phone; the project name is longer than a pill
  # may be anywhere.
  let(:long_project_name) { 'Internationales Kundenprojekt mit besonders langem Projektnamen' }

  def phone_width(width, mobile: true)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 844,
                                                                          deviceScaleFactor: 1, mobile: mobile)
  end

  # The right edge of the open menu of `pill` and the screen's width.
  def menu_edge(pill)
    page.evaluate_script(<<~JS)
      (() => {
        const menu = document.querySelector('details[data-filter-pill="#{pill}"][open] > div')
        return { right: Math.round(menu.getBoundingClientRect().right), screen: document.documentElement.clientWidth }
      })()
    JS
  end

  # What lies past an edge, and how far `scroller` scrolls sideways. The
  # controls (pills, "+ Filter", the search) must stay inside the panel's area
  # (`scope`). An OPEN menu is a layer over the page: it may reach past the
  # panel, but never past the screen (menu_fit.js keeps 8px free).
  def overflow_within(scope, scroller)
    page.evaluate_script(<<~JS)
      (() => {
        const scope = document.querySelector(#{scope.to_json})
        const scroller = #{scroller == :page ? 'document.documentElement' : "document.querySelector(#{scroller.to_json})"}
        const screen = document.documentElement.clientWidth
        const area = Math.min(scope.getBoundingClientRect().right, screen)
        const panel = scope.querySelector('[data-filter-pill="period"]').closest('.grid')
        const past = (el, edge) => { const r = el.getBoundingClientRect(); return r.width > 0 && (r.right > edge + 0.5 || r.left < -0.5) }
        const name = el => el.getAttribute('data-filter-pill') || el.getAttribute('data-filter-add') || el.type
        const controls = [...panel.querySelectorAll('[data-filter-pill], [data-filter-add], input[type="search"]')]
        const menus = [...panel.querySelectorAll('details[open] > div')]
        return {
          scroll: scroller.scrollWidth - scroller.clientWidth,
          beyond: controls.filter(el => past(el, area)).map(name)
                          .concat(menus.filter(el => past(el, screen - 8)).map(el => 'menu of ' + name(el.parentElement)))
        }
      })()
    JS
  end

  # Opens every menu of the panel with a real click and measures it open.
  def each_menu_opened(scope, at_least:)
    count = page.all("#{scope} details[data-filter-pill], #{scope} details[data-filter-add]").size
    expect(count).to be >= at_least
    count.times do |index|
      details = page.all("#{scope} details[data-filter-pill], #{scope} details[data-filter-add]")[index]
      details.find(:xpath, './summary').click
      expect(details[:open]).not_to be_nil
      after_toggle
      yield details['data-filter-pill'] || details['data-filter-add'], details
      details.find(:xpath, './summary').click
    end
  end

  def after_toggle
    # The <details>' toggle event, and the ResizeObserver behind it, are queued
    # after the click; measuring at once raced them.
    page.evaluate_async_script('requestAnimationFrame(() => requestAnimationFrame(arguments[0]))')
  end

  def open_drawer
    find('button[data-filter-count]').click
    expect(page).to have_css("#{drawer} [data-filter-pill=\"period\"]", visible: true)
  end

  let(:drawer) { '[data-mobile-filter-drawer-target="drawer"]' }

  # Long names wherever a name can stand: a chosen project and a chosen
  # billing (both pills), a person in the "+ Filter" menu (it widens the menu
  # after it was placed, second review).
  let(:long_project) { create(:project, organisation: organisation, name: long_project_name) }
  let(:long_group) do
    create(:time_session_group, organisation: organisation,
                                name: 'Abrechnung fuer internationales Kundenprojekt September 2026')
  end

  def book_long_names
    colleague = create(:user, first_name: 'Maximilian-Alexander', last_name: 'Hohenzollern-Sigmaringen')
    create(:membership, user: colleague, organisation: organisation, role: create(:role, organisation: organisation))
    ticket = create(:ticket, project: long_project, title: 'Ticket mit Zeit', tag_list: 'kunde-a')
    [user, colleague].each do |creator|
      create(:time_session, organisation: organisation, project: long_project, creator: creator, ticket: ticket,
                            duration: 60, occurred_on: Date.current, time_session_group: long_group)
    end
  end

  it 'keeps the time filter drawer within the screen, menus open or closed' do
    phone_width(375)
    book_long_names

    visit organisation_time_sessions_path(organisation, viewport: 'mobile', date_range: 'all',
                                                        project_id_filter: long_project.id,
                                                        time_session_group_id: long_group.id)
    open_drawer
    expect(page).to have_css("#{drawer} [data-filter-add=\"add\"]", visible: true)

    expect(overflow_within(drawer, drawer)).to eq('scroll' => 0, 'beyond' => [])
    # period, project, subject, + Filter, billing
    each_menu_opened(drawer, at_least: 5) do |menu, details|
      expect(overflow_within(drawer, drawer)).to eq('scroll' => 0, 'beyond' => []), menu
      # Opening a section of "+ Filter" widens its menu after it was placed.
      sections = details.all(:xpath, './div//details[@data-filter-add-section]/summary')
      sections.each do |section|
        section.click
        after_toggle
        expect(overflow_within(drawer, drawer)).to eq('scroll' => 0, 'beyond' => []), "#{menu} > #{section.text}"
      end
    end
  end

  # A menu that is already open when the screen narrows (turning the phone,
  # resizing the window) is placed again (second review).
  it 'moves an open menu back into view when the screen narrows' do
    phone_width(844)
    book_long_names
    visit organisation_time_sessions_path(organisation, viewport: 'mobile', date_range: 'all')
    open_drawer
    find("#{drawer} [data-filter-pill=\"project\"] > summary").click
    after_toggle

    phone_width(375)
    after_toggle

    expect(overflow_within(drawer, drawer)).to eq('scroll' => 0, 'beyond' => [])
  end

  # A narrower window that leaves the menu its size: the observer sees nothing,
  # only the window's resize does. On a desktop the subject menu is 24rem wide
  # at 1400 and at 1200 px alike (third review: it ended at x = 1218 of 1200).
  it 'moves an open menu into view when the window narrows but the menu keeps its size' do
    phone_width(1400, mobile: false)
    book_long_names
    visit organisation_time_sessions_path(organisation, date_range: 'all', project_id_filter: long_project.id,
                                                        time_session_group_id: long_group.id)
    find('[data-filter-pill="subject"] > summary').click
    after_toggle
    width_before = page.evaluate_script(
      "document.querySelector('details[data-filter-pill=\"subject\"][open] > div').getBoundingClientRect().width"
    )

    phone_width(1200, mobile: false)
    after_toggle

    expect(page.evaluate_script(
             "document.querySelector('details[data-filter-pill=\"subject\"][open] > div').getBoundingClientRect().width"
           )).to eq(width_before)
    edge = menu_edge('subject')
    expect(edge['right']).to be <= edge['screen'] - 8
  end

  # Stimulus connects a target before its controller, so a listener set up in
  # menuTargetConnected must not depend on anything connect() prepares, and a
  # controller that is disconnected and connected again must leave exactly one
  # resize listener behind (third review: they piled up, 1 to 4).
  it 'keeps one working resize listener across reconnects' do
    phone_width(1400, mobile: false)
    book_long_names
    visit organisation_time_sessions_path(organisation, date_range: 'all', project_id_filter: long_project.id,
                                                        time_session_group_id: long_group.id)
    # The listeners registered from here on, as the browser holds them: the
    # same function twice is one, removing one never added is nothing.
    page.execute_script(<<~JS)
      const add = window.addEventListener, remove = window.removeEventListener
      const live = new Set()
      window.addEventListener = function (type, fn, ...rest) { if (type === 'resize') live.add(fn); return add.call(this, type, fn, ...rest) }
      window.removeEventListener = function (type, fn, ...rest) { if (type === 'resize') live.delete(fn); return remove.call(this, type, fn, ...rest) }
      window.__resizeNet = () => live.size
    JS
    3.times do
      page.execute_script(<<~JS)
        const pill = document.querySelector('details[data-filter-pill="subject"]')
        const parent = pill.parentNode, next = pill.nextSibling
        pill.remove()
        parent.insertBefore(pill, next)
      JS
      after_toggle
    end
    # The listener from before the first reconnect was removed for real (it
    # is not in the set, it was added before counting began); every later
    # reconnect removed and re-added the SAME bound function. One is left.
    # Unbound, each connect added a new one: three.
    expect(page.evaluate_script('window.__resizeNet()')).to eq(1)

    find('[data-filter-pill="subject"] > summary').click
    after_toggle
    phone_width(1200, mobile: false)
    after_toggle
    edge = menu_edge('subject')
    expect(edge['right']).to be <= edge['screen'] - 8
  end

  # The custom period renders its menu OPEN (its date fields live in it), in a
  # drawer that is hidden until the filter button is pressed. The menu gets
  # its size only then, and must be placed then (second review, 320px). The
  # drawer opens from the keyboard here: a pointer press outside the menu
  # closes it (details-autoclose), which would hide what is under test.
  it 'places a menu that was open before the drawer was shown' do
    phone_width(320)
    book_long_names
    visit organisation_time_sessions_path(organisation, viewport: 'mobile', date_range: 'custom')
    find('button[data-filter-count]').send_keys(:enter)
    expect(page).to have_css("#{drawer} [data-filter-pill=\"period\"]", visible: true)
    after_toggle

    expect(page).to have_css("#{drawer} details[data-filter-pill=\"period\"][open]")
    expect(overflow_within(drawer, drawer)).to eq('scroll' => 0, 'beyond' => [])
  end

  # The billings list draws its own filter panel from the same grid and the
  # same 420px search field, straight on the page rather than in a drawer.
  it 'keeps the billings filter panel within the screen, menus open or closed' do
    phone_width(375)
    group = create(:time_session_group, organisation: organisation, name: 'August 2026')
    create(:time_session, organisation: organisation, project: long_project, creator: user, duration: 60,
                          occurred_on: Date.current, time_session_group: group)

    visit organisation_time_session_groups_path(organisation, viewport: 'mobile', project_id: long_project.id)
    scope = 'form[action$="/time-tracking/billings"], form[data-turbo-frame="time_session_groups_list_frame"]'
    expect(page).to have_css('[data-filter-pill="period"]')

    expect(overflow_within(scope, :page)).to eq('scroll' => 0, 'beyond' => [])
    # period, project
    each_menu_opened(scope, at_least: 2) do |menu|
      expect(overflow_within(scope, :page)).to eq('scroll' => 0, 'beyond' => []), menu
    end
  end
end
