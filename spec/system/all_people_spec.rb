# frozen_string_literal: true

require 'rails_helper'

# What: the people above the organisations (GET /people) in a browser: the search answers
#       while typing and redraws the count and the select beside it, the select narrows to
#       one organisation and keeps the search, and the chip of a person of two
#       organisations opens that organisation's people page with the person in the lane.
# Why:  the search form, the list frame, the stream that redraws the tools inside the
#       frame's answer and the links that have to leave the frame only meet in a browser.
#       The request spec sees the markup, not whether a click inside a frame leaves it.
RSpec.describe 'People above the organisations', type: :system, inbox_e2e: true do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  before do
    Prosopite.pause
    join_organisation(user, north, admin: true)
    join_organisation(user, south, admin: true)
    join_organisation(shared, north)
    join_organisation(shared, south)
    person_in(north, name: 'Nora Nord', function: 'Leitung IT', company: 'Hosting AG')
    person_in(south, name: 'Sina Sued', function: 'Vertrieb', company: 'Suedwind AG')
    sign_in user
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def list = find("turbo-frame##{AllPeopleController::LIST_FRAME_ID}")

  def count_of(number) = I18n.t('views.all_people.count', count: number)

  # The first click of a file can meet a browser that has not connected the controller yet.
  def open_search
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    find('[data-all-people] button[data-fb-search-open-button]').click
    expect(page).to have_css('#all-people-search', visible: true)
  end

  def change_search_and_organisation(query, organisation)
    page.execute_script(<<~JS, query, organisation.id)
      const search = document.getElementById('all-people-search')
      search.value = arguments[0]
      search.dispatchEvent(new Event('input', { bubbles: true }))
      const organisation = document.getElementById('all-people-organisation')
      organisation.value = arguments[1]
      organisation.dispatchEvent(new Event('change', { bubbles: true }))
    JS
  end

  it 'narrows the list while typing, and the organisation select keeps the search' do
    visit all_people_path
    expect(list).to have_text('Nora Nord')
    expect(list).to have_text('Sina Sued')
    expect(page).to have_css('[data-all-people-count]', text: count_of(4))

    open_search
    find('#all-people-search').send_keys('Vertrieb')

    expect(list).to have_no_text('Nora Nord')
    expect(list).to have_text('Sina Sued')
    expect(page).to have_current_path(/q=Vertrieb/)
    # The tools stand outside the frame and were drawn again by the stream in its answer.
    expect(page).to have_css('[data-all-people-count]', text: count_of(1))
    expect(page).to have_css('#all-people-search:focus')

    select 'Nord GmbH', from: 'all-people-organisation'

    expect(page).to have_current_path(/org=#{north.id}/)
    expect(page).to have_current_path(/q=Vertrieb/)
    expect(page).to have_css('[data-all-people-empty="no-hits"]')
  end

  it 'narrows to one organisation through the select' do
    visit all_people_path
    expect(list).to have_text('Nora Nord')
    wait_for_stimulus('form[data-all-people-tool="organisation"]', 'auto-submit')

    select 'Sued AG', from: 'all-people-organisation'

    expect(page).to have_current_path(/org=#{south.id}/)
    expect(list).to have_no_text('Nora Nord')
    expect(list).to have_text('Sina Sued')
    expect(list).to have_text('Mara Mitglied')
    expect(page).to have_css('[data-all-people-count]', text: count_of(3))
  end

  # Both events happen in one browser task, before the search's debounce can fire.
  # Waiting for a search response here would hide the stale hidden q of the select.
  [[nil, 'Sina'], ['Nora', 'Sina'], ['Nora', '']].each do |previous, query|
    it "keeps #{query.inspect} when switching organisation with #{previous.inspect} as the last rendered search" do
      visit all_people_path(q: previous)
      open_search unless previous
      wait_for_stimulus('.all-people-search', 'auto-submit')
      wait_for_stimulus('form[data-all-people-tool="organisation"]', 'auto-submit')

      change_search_and_organisation(query, south)

      expect(page).to have_current_path(/org=#{south.id}/)
      expect(Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)['q'].to_s).to eq(query)
      expect(list).to have_text('Sina Sued')
      expect(list).to have_no_text('Nora Nord')
      expect(page).to have_css('[data-all-people-count]', text: count_of(query.empty? ? 3 : 1))
    end
  end

  it 'keeps the current search and organisation when an earlier search response arrives late' do
    ready = Queue.new
    release = Queue.new
    finished = Queue.new
    allow(People::AcrossOrganisations).to receive(:call).and_wrap_original do |read, **arguments|
      result = read.call(**arguments)
      if arguments[:query] == 'Nora'
        ready.push(true)
        release.pop
        finished.push(true)
      end
      result
    end

    visit all_people_path
    open_search
    wait_for_stimulus('.all-people-search', 'auto-submit')
    wait_for_stimulus('form[data-all-people-tool="organisation"]', 'auto-submit')

    # Hold the old read on the server until the new organisation page is shown.
    find('#all-people-search').set('Nora')
    Timeout.timeout(Capybara.default_max_wait_time) { ready.pop }
    change_search_and_organisation('Sina', south)

    expect(page).to have_current_path(/org=#{south.id}/)
    expect(page).to have_css('[data-all-people-count]', text: count_of(1))
    release.push(true)
    Timeout.timeout(Capybara.default_max_wait_time) { finished.pop }
    page.server.wait_for_pending_requests
    expect(page).to have_current_path(/q=Sina/)
    expect(page).to have_current_path(/org=#{south.id}/)
    expect(list).to have_text('Sina Sued')
    expect(list).to have_no_text('Nora Nord')
    expect(page).to have_css('#all-people-search', visible: true)
    expect(find('#all-people-search').value).to eq('Sina')
  ensure
    release&.push(true)
  end

  it 'cancels the pending search while the organisation visit is still waiting' do
    visit all_people_path
    open_search
    wait_for_stimulus('.all-people-search', 'auto-submit')
    wait_for_stimulus('form[data-all-people-tool="organisation"]', 'auto-submit')
    page.execute_script <<~JS
      window.peopleSearchRequests = 0
      document.addEventListener('turbo:before-fetch-request', event => {
        if (event.target.matches('.all-people-search')) window.peopleSearchRequests += 1
        if (event.target.matches('form[data-all-people-tool="organisation"]')) {
          event.preventDefault()
          window.resumePeopleFilter = event.detail.resume
          document.body.setAttribute('data-people-filter-waiting', 'true')
        }
      })
    JS
    change_search_and_organisation('Sina', south)
    expect(page).to have_css('body[data-people-filter-waiting="true"]')

    # Wait past the actual search debounce while the filter request is paused.
    requests = page.evaluate_async_script <<~JS
      const done = arguments[arguments.length - 1]
      const form = document.querySelector('.all-people-search')
      const search = window.Stimulus.getControllerForElementAndIdentifier(form, 'auto-submit')
      setTimeout(() => done(window.peopleSearchRequests), search.debounceValue + 100)
    JS
    expect(requests).to eq(0)
    page.execute_script('window.resumePeopleFilter()')
    expect(page).to have_current_path(/org=#{south.id}/)
    expect(page).to have_current_path(/q=Sina/)
    expect(list).to have_text('Sina Sued')
  end

  it 'keeps organisation links inside a phone screen with long person and organisation names' do
    shared.update!(first_name: 'Alexandra', last_name: 'von Hohenlohe-Schillingsfuerst')
    south.update!(name: 'Sueddeutsche Beratungsgesellschaft AG')
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
    visit all_people_path

    row = find('tr[data-all-people-row]', text: shared.display_name)
    expect(row).to have_css('a[data-organisation-chip]', count: 2)
    widths = page.evaluate_script(<<~JS)
      ({ page: document.documentElement.scrollWidth,
         chips: [...document.querySelectorAll('[data-organisation-chip]')].map(chip => chip.getBoundingClientRect().right) })
    JS
    expect(widths['page']).to be <= 390
    expect(widths['chips']).to all(be <= 390)
    row.find('a[data-organisation-chip]', text: south.name).click
    expect(page).to have_current_path(organisation_people_path(south, member_id: shared.id))
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end

  it 'opens the people page of an organisation with the person in the lane, through the chip of a person of two' do
    visit all_people_path
    row = find('tr[data-all-people-row]', text: 'Mara Mitglied')
    expect(row).to have_css('a[data-organisation-chip]', count: 2)

    row.find('a[data-organisation-chip]', text: 'Sued AG').click

    expect(page).to have_current_path(organisation_people_path(south, member_id: shared.id))
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_text('Mara Mitglied')
    expect(page).to have_css('.people-row.selected-row', text: 'Mara Mitglied')
  end

  it 'opens a person of one organisation through the name' do
    visit all_people_path

    find('tr[data-all-people-row]', text: 'Sina Sued').click_link('Sina Sued')

    sina = ActsAsTenant.with_tenant(south) { Person.find_by!(name: 'Sina Sued') }
    expect(page).to have_current_path(organisation_people_path(south, person_id: sina.id))
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_text('Sina Sued')
  end
end
