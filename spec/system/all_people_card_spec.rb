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

  # The colour of --ink as the browser computes a colour.
  def ink
    channels = page.evaluate_script("getComputedStyle(document.documentElement).getPropertyValue('--ink')").split
    "rgb(#{channels.join(', ')})"
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

  # Review of #197: a row click writes the address and marks the row before the answer
  # comes. For a person deleted after the list was drawn the answer is "gone", and that
  # lane had no cross: only Escape or a second click on the row closed it.
  it 'shows a person deleted after the list was drawn as gone, and closes that lane with the cross' do
    visit_list
    ActsAsTenant.with_tenant(north) { Person.where(id: nora.id).delete_all }

    row('Nora Nord').find('.all-people-row__name').click

    expect(lane).to have_text(I18n.t('views.all_people.card.missing_title'))
    wait_until_still("turbo-frame##{AllPeopleController::CARD_FRAME_ID} [data-lane-close]")
    lane.find('[data-lane-close]').click

    expect(page).to have_no_css('tr[data-all-people-row].selected-row')
    expect(page).to have_current_path(all_people_path)
  end

  # Review of #197: the row switched the ring of the keyboard off (outline-none) and
  # showed the focus only as the hover tone, which the open row's own tone covers.
  it 'shows the keyboard focus on a row with the ring of the app, also on the open one' do
    visit_list
    open_card('Kai Kontakt')

    ['Kai Kontakt', 'Nora Nord'].each do |name|
      element = row(name)
      element.send_keys(:shift) # keyboard focus, the way :focus-visible counts it
      expect(page.evaluate_script('document.activeElement.matches(":focus-visible")')).to be(true)
      ring = page.evaluate_script(<<~JS, element)
        (() => { const style = getComputedStyle(arguments[0]); return [style.outlineStyle, style.outlineWidth, style.outlineColor] })()
      JS
      expect(ring).to eq(['solid', '2px', ink]), "expected the ring on the row of #{name}"
    end
  end

  # Review of #197: in the list column of the lane layout the rules of the ticket table
  # (layout.css, ".list table") took the head's air and drew its rule and the table's end
  # in black, which the dark theme does not change.
  it 'keeps the head and the lines the table has of its own in the list column' do
    visit_list
    style = ->(selector, property) { page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).#{property}") }

    expect([style.call('.all-people-table th', 'paddingTop'), style.call('.all-people-table th', 'paddingBottom')]).to eq(%w[31px 15px])
    expect(style.call('.all-people-table th', 'borderBottomColor')).to eq(ink)
    expect(style.call('.all-people-table', 'borderBottomStyle')).to eq('none')
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

  # A refused save answers in place and the address keeps ?edit=. Leaving the form then
  # has to change the address, or a reload would open the form the reader just closed.
  it 'leaves a form the pencil opened after a refused save, and the address stops naming the form' do
    visit_list
    open_card('Kai Kontakt')
    lane.all('[data-card-field="function"] a[data-card-pencil]').first.click
    form = find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")
    expect(form).to have_field('person_name', with: 'Kai Kontakt')

    # The browser would hold an empty name back itself; the server is the one asked here.
    page.execute_script("document.getElementById('person_name').removeAttribute('required')")
    form.fill_in 'person_name', with: ''
    form.click_button I18n.t('views.organisations.people.form.save')

    expect(page).to have_css('.people-callout--danger')
    expect(page).to have_current_path(organisation_people_path(north, edit: north_kai.id))
    find('.people-form-wrap a.people-quiet-action').click

    expect(page).to have_current_path(organisation_people_path(north, person_id: north_kai.id))
    expect(page).to have_no_field('person_name')
    visit page.current_url
    expect(page).to have_no_field('person_name')
    expect(find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")).to have_text('Kai Kontakt')
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

  # The copy is merged with its source, so its card on this page is the card of both.
  it 'takes a contact over from the card and stays on the page: the card of the copy opens with both sources' do
    visit_list
    open_card('Nora Nord')
    lane.find('details.more-menu summary').click
    lane.find('a[data-card-takeover]').click
    dialog = find('[role="dialog"]')

    dialog.find('button[type="submit"]', text: I18n.t('views.organisations.people.takeover.submit')).click

    expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
    expect(page).to have_current_path(all_people_path, ignore_query: true)
    expect(ActsAsTenant.with_tenant(south) { Person.where(name: 'Nora Nord').count }).to eq(1)
    expect(lane).to have_css('[data-card-source]', count: 2)
    expect(lane.all('[data-card-source] .organisation-chip__name').map(&:text)).to eq(['Nord GmbH', 'Sued AG'])
    # The answer names the copy's card; the address takes the row's, its first source.
    expect(card_param).to eq("#{north.id}:person:#{nora.id}")
  end

  # One menu offers the dialogs of two contacts. Each returns the focus to the "···"
  # button; the dialog of the second contact sent it to an id no page has.
  it 'returns the focus to the menu of the card after the dialog of the second contact closes' do
    visit_list
    open_card('Kai Kontakt')
    lane.find('details.more-menu summary').click
    lane.all('a[data-card-takeover]').last.click
    dialog = find('[role="dialog"]')
    expect(dialog).to have_text('Kai Kontakt')
    expect(page).to have_no_css('[data-lane-head] details.more-menu[open]')

    dialog.find("button[aria-label='#{I18n.t('views.organisations.people.takeover.close')}']").click

    expect(page).to have_no_css('[role="dialog"]')
    expect(page).to have_css("##{AllPeopleHelper::CARD_MORE_ACTIONS_ID}:focus")
  end

  it 'keeps the card open when the list is narrowed to one organisation' do
    visit_list
    open_card('Kai Kontakt')

    select 'Sued AG', from: 'all-people-organisation'

    expect(list).to have_no_text('Nora Nord')
    expect(page).to have_current_path(/org=#{south.id}/)
    expect(lane).to have_css('[data-all-people-card]', text: 'Einkauf')
    # The row of the narrowed list carries the source of the south: the address names it.
    expect(card_param).to eq("#{south.id}:person:#{south_kai.id}")
    expect(page).to have_css('tr[data-all-people-row].selected-row', count: 1, text: 'Kai Kontakt')
  end

  it 'keeps the card open after merging two ticked rows beside it' do
    south_nora = person_in(south, name: 'N. Nord', function: 'Leitung Technik')
    visit_list
    wait_for_stimulus('[data-all-people]', 'all-people-merge')
    open_card('Nora Nord')

    ['Nora Nord', 'N. Nord'].each { |name| row(name).find('input[type="checkbox"]').click }
    find('form#all-people-merge button[type="submit"]').click

    expect(page).to have_text(I18n.t('controllers.people.merge.success'))
    expect(page).to have_no_css('tr[data-all-people-row]', text: 'N. Nord')
    expect(card_param).to eq("#{north.id}:person:#{nora.id}")
    expect(lane).to have_css('[data-all-people-card]', text: 'Leitung Technik')
    expect(PersonGroupEntry.where(owner_id: user.id, person_id: south_nora.id)).to exist
  end

  # An address that names the person by a later source (an old link): the row carries
  # its first source. The address takes the row's, so the search that draws the rows again
  # keeps the mark, and a click on the row closes the lane instead of opening it again.
  it 'keeps the row of a card named by a later source marked through a search, and closes it with a click' do
    visit_list(card: "#{south.id}:person:#{south_kai.id}")
    expect(lane).to have_css('[data-all-people-card]', text: 'Einkauf')
    expect(card_param).to eq(kai_address)
    wait_for_stimulus('[data-all-people] [data-fb-search]', 'search-disclosure')
    wait_until_still('[data-all-people] button[data-fb-search-open-button]')
    find('[data-all-people] button[data-fb-search-open-button]').click

    find('#all-people-search').send_keys('Kai')

    expect(list).to have_no_text('Nora Nord')
    expect(page).to have_css('tr[data-all-people-row].selected-row', count: 1, text: 'Kai Kontakt')
    row('Kai Kontakt').find('.all-people-row__name').click
    expect(page).to have_no_css('tr[data-all-people-row].selected-row')
    expect(card_param).to be_nil
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

  it 'adds a first detail through the source link of a member without any rows' do
    member = create(:user, first_name: 'Mara', last_name: 'Mitglied')
    [north, south].each { |organisation| join_organisation(member, organisation) }
    visit_list
    open_card('Mara Mitglied')
    lane.find('a[data-card-edit]').click
    expect(lane).to have_css('a[data-card-edit-done]')
    wait_until_still('[data-all-people-card] [data-lane-close]')

    lane.find('a[data-card-source-edit]', text: I18n.t('views.all_people.card.edit_in', organisation: south.name)).click

    expect(page).to have_current_path(organisation_people_path(south, new: 'person', user_id: member.id))
    form = find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")
    form.fill_in 'person_phone', with: '+49 30 5550123'
    form.click_button I18n.t('views.organisations.people.form.save')
    expect(page).to have_no_css('.people-form-wrap')
    expect(ActsAsTenant.with_tenant(south) { Person.find_by!(user_id: member.id).phone }).to eq('+49 30 5550123')
    expect(ActsAsTenant.with_tenant(north) { Person.where(user_id: member.id).exists? }).to be(false)
  end

  it 'keeps the live search when cancelling a form opened by its address' do
    visit organisation_people_path(north, edit: north_kai.id, q: 'Kai')
    wait_for_stimulus('.people-page', 'layout-toggle')
    expect(page).to have_field('person_function', with: 'Einkauf')
    wait_for_stimulus('[data-fb-search]', 'search-disclosure')
    find('[data-fb-search-open-button]').click unless page.has_css?('#people-search', visible: true, wait: 0)
    fill_in 'people-search', with: 'Nora'
    expect(page).to have_current_path(/q=Nora/)
    expect(find("turbo-frame##{Organisations::PeopleController::LIST_FRAME_ID}")).to have_text('Nora Nord')
    find('.people-form-wrap a.people-quiet-action').click
    expect(page).to have_no_css('.people-form-wrap')
    expect(page).to have_current_path(/q=Nora/)
  end

  %w[split detach].each do |action|
    it "keeps page 2 after #{action} from a card whose controls were refreshed" do
      west = create(:organisation, name: 'West KG')
      join_organisation(user, west, admin: true)
      west_kai = person_in(west, name: 'Kai Kontakt')
      create(:person_group_entry, person_group: merge, organisation: west, person_id: west_kai.id)
      51.times { |i| person_in(north, name: format('Aaron %02d', i)) }
      visit_list(page: 2)
      open_card('Kai Kontakt')
      lane.find('a[data-card-edit]').click
      expect(lane).to have_css('a[data-card-edit-done]')
      wait_until_still('[data-all-people-card] [data-lane-close]')
      lane.find('details.more-menu summary').click

      accept_confirm { lane.all("form[data-card-#{action}] button").last.click }

      expect(lane).to have_css('[data-card-source]', count: action == 'split' ? 1 : 2)
      expect(page).to have_current_path(/page=2/)
      expect(list).to have_text('Kai Kontakt')
    end
  end
end
