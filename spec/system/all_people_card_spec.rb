# frozen_string_literal: true

require 'rails_helper'

# What: the card of a person in the lane of the people list above the organisations, in a
#       browser: a click on a row opens it beside the list, the address carries it, the
#       switch "Quellen zeigen" stays on over a reload, a pencil lands in the form of that
#       row on the people page of its organisation and Back returns, the takeover dialog
#       of an organisation opens on this page, and a merge is undone from the card.
# Why:  the row opener, the lane frame that asks the page's own address, the switch that
#       answers inside the frame, the links that have to leave it and the dialog of
#       another controller only meet in a browser. The request spec sees the markup, not
#       whether a click opens the lane, whether the address follows, or where Back goes.
RSpec.describe 'People above the organisations, the card', type: :system, inbox_e2e: true do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let!(:north_kai) do
    person_in(north, name: 'Kai Kontakt', function: 'Einkauf', company: 'Nordlicht AG', email: 'kai@example.com',
                     phone: '+49 30 5550100', notes: 'Nur dienstags im Haus.')
  end
  let!(:south_kai) do
    person_in(south, name: 'Kai Kontakt', function: 'Vertrieb', company: 'Nordlicht AG', email: 'kai@example.com', phone: nil)
  end
  let!(:nora) { person_in(north, name: 'Nora Nord', function: 'Leitung IT', company: 'Hosting AG', email: 'nora@example.com') }
  let!(:merge) do
    create(:person_group, owner: user).tap do |group|
      create(:person_group_entry, person_group: group, organisation: north, person_id: north_kai.id)
      create(:person_group_entry, person_group: group, organisation: south, person_id: south_kai.id)
    end
  end
  let(:kai_address) { "#{north.id}:person:#{north_kai.id}" }

  before do
    Prosopite.pause
    join_organisation(user, north, admin: true)
    join_organisation(user, south, admin: true)
    sign_in user
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def list = find("turbo-frame##{AllPeopleController::LIST_FRAME_ID}")

  def lane = find("turbo-frame##{AllPeopleController::CARD_FRAME_ID}")

  def row(name) = find('tr[data-all-people-row]', text: name)

  def card_param
    Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)['card']
  end

  # The first click of a file can meet a browser that has not connected the controllers yet.
  def visit_list(**params)
    visit all_people_path(**params)
    wait_for_stimulus('[data-all-people]', 'layout-toggle')
    wait_for_stimulus('[data-all-people]', 'index-page')
    wait_for_stimulus('tr[data-all-people-row]', 'list-row')
  end

  # The lane slides open in 0.25 s and everything in it moves with it: wait until the
  # card's head has come to rest before a click on one of its controls.
  def open_card(name)
    row(name).find('.all-people-row__name').click
    expect(lane).to have_css('[data-all-people-card]', text: name)
    wait_until_still('[data-all-people-card] [data-lane-close]')
  end

  def chips_at(key)
    lane.all(%([data-card-field="#{key}"] [data-organisation-chip]), minimum: 0).map(&:text)
  end

  it 'opens the card beside the list on a click, carries it in the address and shows it again after a reload' do
    visit_list
    expect(page).to have_no_css('[data-all-people-card]')

    open_card('Kai Kontakt')

    # The list stays, and the row of the open person is marked.
    expect(list).to have_text('Nora Nord')
    expect(page).to have_css('tr[data-all-people-row].selected-row', count: 1, text: 'Kai Kontakt')
    expect(page).to have_current_path(all_people_path, ignore_query: true)
    expect(card_param).to eq(kai_address)
    # The organisations are named only where they differ.
    expect(chips_at('function')).to eq(['Nord GmbH', 'Sued AG'])
    expect(chips_at('company')).to be_empty
    expect(lane).to have_text(I18n.t('views.all_people.card.missing_value'))

    visit page.current_url

    expect(lane).to have_css('[data-all-people-card]', text: 'Einkauf')
    expect(list).to have_text('Nora Nord')
    expect(page).to have_css('tr[data-all-people-row].selected-row', count: 1, text: 'Kai Kontakt')
    expect(card_param).to eq(kai_address)
  end

  it 'opens another card from the next row and closes the lane with the cross' do
    visit_list
    open_card('Kai Kontakt')

    row('Nora Nord').find('.all-people-row__name').click

    expect(lane).to have_css('[data-all-people-card]', text: 'Nora Nord')
    expect(lane).to have_no_text('Kai Kontakt')
    expect(card_param).to eq("#{north.id}:person:#{nora.id}")
    expect(page).to have_css('tr[data-all-people-row].selected-row', count: 1, text: 'Nora Nord')
    # A person of one organisation: no chip at a value.
    expect(lane).to have_no_css('[data-card-value] [data-organisation-chip]')

    wait_until_still('[data-all-people-card] [data-lane-close]')
    lane.find('[data-lane-close]').click

    expect(page).to have_no_css('tr[data-all-people-row].selected-row')
    expect(page).to have_current_path(all_people_path)
    expect(list).to have_text('Kai Kontakt')
  end

  it 'keeps the tick of a row out of the click that opens the card' do
    visit_list
    wait_for_stimulus('[data-all-people]', 'all-people-merge')

    row('Nora Nord').find('input[type="checkbox"]').click

    expect(row('Nora Nord').find('input[type="checkbox"]')).to be_checked
    expect(page).to have_no_css('[data-all-people-card]')
    expect(page).to have_current_path(all_people_path)
  end

  it 'names the organisations at every value with the switch, and keeps it on over a reload' do
    visit_list
    open_card('Kai Kontakt')
    expect(chips_at('company')).to be_empty

    lane.find('[data-card-sources-switch] button').click

    expect(lane).to have_css('[data-card-sources-switch] button[aria-pressed="true"]')
    expect(chips_at('company')).to eq(['Nord GmbH', 'Sued AG'])
    # The switch answers inside the lane: the page, its list and its address stay.
    expect(list).to have_text('Nora Nord')
    expect(card_param).to eq(kai_address)

    visit page.current_url

    expect(lane).to have_css('[data-card-sources-switch] button[aria-pressed="true"]')
    expect(chips_at('company')).to eq(['Nord GmbH', 'Sued AG'])

    wait_until_still('[data-all-people-card] [data-lane-close]')
    lane.find('[data-card-sources-switch] button').click

    expect(lane).to have_css('[data-card-sources-switch] button[aria-pressed="false"]')
    expect(chips_at('company')).to be_empty
    expect(chips_at('function')).to eq(['Nord GmbH', 'Sued AG'])
  end

  it 'names the organisations at every value while "Bearbeiten" is on, and takes them back with "Fertig"' do
    visit_list
    open_card('Kai Kontakt')

    lane.find('a[data-card-edit]').click

    expect(lane).to have_css('a[data-card-edit-done]')
    expect(chips_at('company')).to eq(['Nord GmbH', 'Sued AG'])
    expect(lane).to have_css('[data-card-field="company"] a[data-card-pencil]', count: 2)

    wait_until_still('[data-all-people-card] [data-lane-close]')
    lane.find('a[data-card-edit-done]').click

    expect(lane).to have_css('a[data-card-edit]')
    expect(chips_at('company')).to be_empty
  end

  it 'lands in the form of that row on the people page of its organisation through a pencil, and Back returns to the card' do
    visit_list
    open_card('Kai Kontakt')

    lane.find('[data-card-field="function"] a[data-card-pencil]', match: :first).hover
    lane.all('[data-card-field="function"] a[data-card-pencil]').last.click

    # The south's row, in the south: its form in the lane of that organisation's page.
    expect(page).to have_current_path(organisation_people_path(south, edit: south_kai.id))
    form = find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")
    expect(form).to have_field('person_function', with: 'Vertrieb')
    expect(form).to have_field('person_name', with: 'Kai Kontakt')
    expect(page).to have_css('.people-row', text: 'Kai Kontakt')

    form.fill_in 'person_function', with: 'Vertriebsleitung'
    form.click_button I18n.t('views.organisations.people.form.save')

    expect(page).to have_current_path(organisation_people_path(south, person_id: south_kai.id))
    expect(ActsAsTenant.with_tenant(south) { south_kai.reload.function }).to eq('Vertriebsleitung')
    expect(ActsAsTenant.with_tenant(north) { north_kai.reload.function }).to eq('Einkauf')

    visit all_people_path(card: kai_address)
    expect(lane).to have_css('[data-all-people-card]', text: 'Vertriebsleitung')
  end

  it 'returns from the form to the card with Back' do
    visit_list
    open_card('Kai Kontakt')
    lane.all('[data-card-field="function"] a[data-card-pencil]').first.click
    expect(page).to have_current_path(organisation_people_path(north, edit: north_kai.id))
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_field('person_function', with: 'Einkauf')

    page.go_back

    expect(page).to have_current_path(all_people_path, ignore_query: true)
    expect(card_param).to eq(kai_address)
    expect(lane).to have_css('[data-all-people-card]', text: 'Kai Kontakt')
    expect(list).to have_text('Nora Nord')
  end

  it 'leads into an organisation through the link of a source' do
    visit_list
    open_card('Kai Kontakt')

    lane.find('a[data-card-source-link]', text: I18n.t('views.all_people.card.open_in', organisation: 'Sued AG')).click

    expect(page).to have_current_path(organisation_people_path(south, person_id: south_kai.id))
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_text('Vertrieb')
  end

  it 'unfolds the notes of a source, which stay text' do
    visit_list
    open_card('Kai Kontakt')
    expect(lane).to have_no_text('Nur dienstags im Haus.')

    lane.find('details[data-card-notes] summary', text: I18n.t('views.all_people.card.notes_from', organisation: 'Nord GmbH')).click

    expect(lane).to have_text('Nur dienstags im Haus.')
    expect(lane).to have_no_css('details[data-card-notes] textarea, details[data-card-notes] a')
  end

  it 'keeps the card open and in the address while the list is searched beside it' do
    visit_list
    open_card('Kai Kontakt')
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    wait_until_still('[data-all-people] button[data-fb-search-open-button]')
    find('[data-all-people] button[data-fb-search-open-button]').click
    expect(page).to have_css('#all-people-search', visible: true)

    find('#all-people-search').send_keys('Nora')

    expect(list).to have_no_text('Kai Kontakt')
    expect(list).to have_text('Nora Nord')
    expect(page).to have_current_path(/q=Nora/)
    expect(card_param).to eq(kai_address)
    expect(lane).to have_css('[data-all-people-card]', text: 'Kai Kontakt')
  end

  it 'opens the takeover dialog of an organisation on the card and closes it again' do
    visit_list
    open_card('Nora Nord')

    lane.find('details.more-menu summary').click
    lane.find('a[data-card-takeover]').click

    dialog = find('[role="dialog"]')
    expect(dialog).to have_text(I18n.t('views.organisations.people.takeover.title'))
    expect(dialog).to have_text('Nora Nord')
    expect(dialog).to have_select('target', with_options: ['Sued AG'])
    # Still the page above the organisations, the card behind the dialog.
    expect(page).to have_current_path(all_people_path, ignore_query: true)

    dialog.find("button[aria-label='#{I18n.t('views.organisations.people.takeover.close')}']").click

    expect(page).to have_no_css('[role="dialog"]')
    expect(lane).to have_css('[data-all-people-card]', text: 'Nora Nord')
  end

  it 'takes a contact over from the card: the copy opens in the other organisation' do
    visit_list
    open_card('Nora Nord')
    lane.find('details.more-menu summary').click
    lane.find('a[data-card-takeover]').click
    dialog = find('[role="dialog"]')

    dialog.find('button[type="submit"]', text: I18n.t('views.organisations.people.takeover.submit')).click

    copy = nil
    expect(page).to have_current_path(%r{\A/org/#{south.id}/people\?person_id=})
    ActsAsTenant.with_tenant(south) { copy = Person.find_by!(name: 'Nora Nord') }
    expect(page).to have_current_path(organisation_people_path(south, person_id: copy.id))
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_text('Nora Nord')
  end

  it 'undoes the merge from the card only after a yes, and comes back to the card of the first source' do
    visit_list
    open_card('Kai Kontakt')
    expect(page).to have_css('tr[data-all-people-row]', text: 'Kai Kontakt', count: 1)

    lane.find('details.more-menu summary').click
    dismiss_confirm { lane.find('form[data-card-split] button').click }
    expect(PersonGroup.where(id: merge.id)).to exist

    lane.find('details.more-menu summary').click unless lane.has_css?('form[data-card-split] button', visible: true, wait: 0)
    accept_confirm { lane.find('form[data-card-split] button').click }

    expect(page).to have_css('tr[data-all-people-row]', text: 'Kai Kontakt', count: 2)
    expect(PersonGroup.where(id: merge.id)).not_to exist
    expect(card_param).to eq(kai_address)
    expect(lane).to have_css('[data-all-people-card]', text: 'Einkauf')
    expect(lane).to have_no_text('Vertrieb')
  end

  it 'shows the card on a phone after a tap on the row, and the way into the organisation from there' do
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
    visit_list

    row('Kai Kontakt').find('.all-people-row__name').click

    expect(page).to have_css('[data-all-people-card]', text: 'Kai Kontakt', visible: true)
    expect(card_param).to eq(kai_address)
    widths = page.evaluate_script(<<~JS)
      ({ page: document.documentElement.scrollWidth,
         card: document.querySelector('[data-all-people-card]').getBoundingClientRect().right })
    JS
    expect(widths['page']).to be <= 390
    expect(widths['card']).to be <= 390

    find('a[data-card-source-link]', text: I18n.t('views.all_people.card.open_in', organisation: 'Sued AG')).click

    expect(page).to have_current_path(organisation_people_path(south, person_id: south_kai.id))
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end
end
