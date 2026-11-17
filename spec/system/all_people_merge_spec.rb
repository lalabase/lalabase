# frozen_string_literal: true

require 'rails_helper'

# What: merging on the people list above the organisations (GET /people) in a browser: tick
#       two rows of two organisations, "Zusammenführen" in the bar, one row with two chips;
#       then "Zusammenführung aufheben" in the menu of that row, which asks first.
# Why:  the ticks stand in the table and belong to the form of the bar only by its id, the
#       bar shows through the stylesheet, its number and its waiting button are a
#       controller's, the answer is a redirect out of a frame, and the menu's delete asks
#       through Turbo. None of that meets anywhere but in a browser: the request spec sees
#       the markup, not whether a click on "no" keeps the merge.
RSpec.describe 'Merging people above the organisations', type: :system, inbox_e2e: true do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  before do
    Prosopite.pause
    join_organisation(user, north, admin: true)
    join_organisation(user, south, admin: true)
    person_in(north, name: 'Kai Kontakt', function: 'Einkauf', company: 'Nordlicht AG')
    person_in(south, name: 'Kai Kontakt (Sued)', function: 'Vertrieb', company: 'Suedwind AG')
    person_in(south, name: 'Sina Sued')
    sign_in user
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def row(name)
    find('tr[data-all-people-row]', text: name, match: :prefer_exact)
  end

  def rows_named(name)
    all('tr[data-all-people-row]').select { |candidate| candidate.find('.all-people-row__name').text == name }
  end

  def chips(name)
    rows_named(name).sole.all('[data-organisation-chip]').map(&:text)
  end

  def tick(name)
    rows_named(name).sole.find('input[type="checkbox"]').check
  end

  # The first click of a file can meet a browser that has not connected the controller yet.
  def open_list
    visit all_people_path
    expect(page).to have_css('tr[data-all-people-row]', count: 4)
    wait_for_stimulus('[data-all-people]', 'all-people-merge')
  end

  def open_menu(name)
    menu = rows_named(name).sole.find('details.more-menu')
    wait_for_stimulus('tr[data-person-key] details.more-menu', 'details-autoclose')
    menu.find('summary').click
    menu
  end

  let(:bar) { 'form#all-people-merge' }
  let(:merge_button) { I18n.t('views.all_people.merge.submit') }
  let(:split_button) { I18n.t('views.all_people.merge.split') }

  it 'merges two ticked rows into one row with two chips, and takes the merge apart again only after a yes' do
    open_list
    expect(page).to have_css(bar, visible: :hidden)
    expect(chips('Kai Kontakt')).to eq(['Nord GmbH'])
    expect(chips('Kai Kontakt (Sued)')).to eq(['Sued AG'])

    # One row is no merge: the bar shows, counts, and its button waits for a second row.
    tick('Kai Kontakt')
    expect(page).to have_css(bar, visible: :visible)
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('1', exact: true)
    expect(page).to have_button(merge_button, disabled: true)

    tick('Kai Kontakt (Sued)')
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('2', exact: true)
    click_button merge_button

    expect(page).to have_text(I18n.t('controllers.people.merge.success'))
    expect(page).to have_css('tr[data-all-people-row]', count: 3)
    expect(chips('Kai Kontakt')).to eq(['Nord GmbH', 'Sued AG'])
    expect(rows_named('Kai Kontakt (Sued)')).to be_empty
    expect(page).to have_css('[data-all-people-count]', text: I18n.t('views.all_people.count', count: 3))
    expect(page).to have_css(bar, visible: :hidden)
    expect([PersonGroup.count, PersonGroupEntry.count]).to eq([1, 2])

    # "No" keeps the merge.
    menu = open_menu('Kai Kontakt')
    dismiss_confirm(I18n.t('views.confirm.split_merged_person', name: 'Kai Kontakt')) { menu.click_button split_button }
    expect(chips('Kai Kontakt')).to eq(['Nord GmbH', 'Sued AG'])
    expect(PersonGroup.count).to eq(1)

    # "Yes" restores the two rows.
    menu = open_menu('Kai Kontakt') unless menu.matches_css?('[open]')
    accept_confirm { menu.click_button split_button }

    expect(page).to have_text(I18n.t('controllers.people.split.success'))
    expect(page).to have_css('tr[data-all-people-row]', count: 4)
    expect(chips('Kai Kontakt')).to eq(['Nord GmbH'])
    expect(chips('Kai Kontakt (Sued)')).to eq(['Sued AG'])
    expect(PersonGroup.count).to eq(0)
  end

  it 'offers no menu on a row no merge joined, and clears the ticks with the bar' do
    open_list

    expect(page).to have_no_css('tr[data-all-people-row] details.more-menu')
    tick('Sina Sued')
    tick('Kai Kontakt')
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('2', exact: true)

    click_button I18n.t('views.all_people.merge.clear')

    expect(page).to have_css(bar, visible: :hidden)
    expect(page).to have_no_css('tr[data-all-people-row] input[type="checkbox"]:checked')
  end

  it 'says why two rows of one organisation are not merged, and merges nothing' do
    open_list
    tick('Sina Sued')
    tick('Kai Kontakt (Sued)')

    click_button merge_button

    expect(page).to have_text(I18n.t('controllers.people.merge.same_organisation'))
    expect(page).to have_css('tr[data-all-people-row]', count: 4)
    expect(PersonGroup.count).to eq(0)
  end

  # Two rows that are the same human are often written differently and stand far apart. The
  # search finds the second one, and it redraws the rows: a tick has to outlive that.
  it 'keeps a ticked row through a search and merges it with a row the search found' do
    open_list
    tick('Kai Kontakt')
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    find('[data-all-people] button[data-fb-search-open-button]').click
    find('#all-people-search').send_keys('Suedwind')

    expect(page).to have_css('tr[data-all-people-row]', count: 1)
    expect(rows_named('Kai Kontakt')).to be_empty
    # The row is out of sight; the bar still counts it and names it.
    expect(page).to have_css(bar, visible: :visible)
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('1', exact: true)
    expect(find("#{bar} [data-all-people-merge-target='names']")).to have_text('Kai Kontakt', exact: true)

    tick('Kai Kontakt (Sued)')
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('2', exact: true)
    expect(find("#{bar} [data-all-people-merge-target='names']")).to have_text('Kai Kontakt, Kai Kontakt (Sued)', exact: true)
    click_button merge_button

    expect(page).to have_text(I18n.t('controllers.people.merge.success'))
    expect(PersonGroupEntry.count).to eq(2)
    expect(page).to have_current_path(/q=Suedwind/)
    expect(chips('Kai Kontakt')).to eq(['Nord GmbH', 'Sued AG'])
  end

  it 'ticks a chosen row again when the search brings it back, and forgets it once it is unticked' do
    open_list
    tick('Kai Kontakt')
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    find('[data-all-people] button[data-fb-search-open-button]').click
    find('#all-people-search').send_keys('Sina')
    expect(page).to have_css('tr[data-all-people-row]', count: 1)

    find('#all-people-search').send_keys([:backspace] * 4)

    expect(page).to have_css('tr[data-all-people-row]', count: 4)
    expect(rows_named('Kai Kontakt').sole.find('input[type="checkbox"]')).to be_checked
    rows_named('Kai Kontakt').sole.find('input[type="checkbox"]').uncheck
    expect(page).to have_css(bar, visible: :hidden)
  end

  it 'keeps the selection controls when the search has no results' do
    open_list
    tick('Kai Kontakt')
    tick('Kai Kontakt (Sued)')
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    find('[data-all-people] button[data-fb-search-open-button]').click
    find('#all-people-search').send_keys('NobodyMatchesThisSearch')

    expect(page).to have_css('[data-all-people-empty="no-hits"]')
    expect(page).to have_no_css('tr[data-all-people-row]')
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('2', exact: true)
    expect(page).to have_button(merge_button, disabled: false)

    click_button I18n.t('views.all_people.merge.clear')

    expect(page).to have_css(bar, visible: :hidden)
    expect(PersonGroup.count).to eq(0)
  end

  it 'retries a failed request with only the new selection after clearing the old one' do
    west = create(:organisation, name: 'West KG')
    east = create(:organisation, name: 'Ost eG')
    [west, east].each { |organisation| join_organisation(user, organisation, admin: true) }
    retry_west = person_in(west, name: 'Retry West')
    retry_east = person_in(east, name: 'Retry Ost')
    visit all_people_path
    wait_for_stimulus('[data-all-people]', 'all-people-merge')
    tick('Kai Kontakt')
    tick('Kai Kontakt (Sued)')
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    find('[data-all-people] button[data-fb-search-open-button]').click
    find('#all-people-search').send_keys('Retry')
    expect(page).to have_css('tr[data-all-people-row]', count: 2)

    # A network failure leaves the form in place, including the off-screen rows carry()
    # added. Retrying that same form must not submit people the user has since discarded.
    page.driver.browser.execute_cdp('Network.enable')
    page.driver.browser.execute_cdp('Network.setBlockedURLs', urls: ['*people/merges*'])
    click_button merge_button
    expect(page).to have_button(merge_button, disabled: false)
    expect(page).to have_css("#{bar} input[type='hidden'][name='rows[]']", count: 2, visible: :all)
    expect(PersonGroup.count).to eq(0)
    page.driver.browser.execute_cdp('Network.setBlockedURLs', urls: [])

    click_button I18n.t('views.all_people.merge.clear')
    tick('Retry West')
    tick('Retry Ost')
    expect(find("#{bar} [data-all-people-merge-target='count']")).to have_text('2', exact: true)
    click_button merge_button

    expect(page).to have_text(I18n.t('controllers.people.merge.success'))
    expect(PersonGroup.count).to eq(1)
    expect(PersonGroupEntry.pluck(:person_id)).to contain_exactly(retry_west.id, retry_east.id)
  ensure
    page.driver.browser.execute_cdp('Network.setBlockedURLs', urls: [])
  end
end
