# frozen_string_literal: true

require 'rails_helper'

# The additional details of a person in the form, with real clicks: adding a
# row from the template, switching the kind (input type and suggestions),
# removing, the limit of ten, saving, and the lane after the save. Only the
# browser runs person_details_controller.
RSpec.describe 'People additional details in the form', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:person) { create(:person, organisation: organisation, name: 'Doris Dienstleister', phone: '+49 30 1234567') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    person
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane
    find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")
  end

  def open_form
    visit organisation_people_path(organisation, person_id: person.id)
    within(lane) { click_link I18n.t('views.organisations.people.show.edit') }
    expect(page).to have_css('[data-controller="person-details"]')
  end

  # A picture for the review, after the page transition has finished (the
  # browser keeps painting the old page until its animations end).
  def screenshot(name)
    page.execute_script('document.getAnimations().forEach((animation) => animation.finish())')
    directory = Rails.root.join('tmp/screenshots')
    FileUtils.mkdir_p(directory)
    page.driver.browser.save_screenshot(directory.join("#{name}.png").to_s)
  end

  def rows
    all('[data-person-details-target="list"] [data-person-details-target="row"]')
  end

  def add_button
    find_button(I18n.t('views.organisations.people.form.add_detail'))
  end

  def remove_label
    I18n.t('views.organisations.people.form.remove_detail')
  end

  def kind_name(kind)
    I18n.t("views.organisations.people.details.kinds.#{kind}")
  end

  it 'adds, switches, removes and saves details, and shows them in the lane' do
    open_form

    add_button.click
    expect(rows.size).to eq(1)
    within(rows[0]) do
      expect(page).to have_css('input[data-person-details-value][type="tel"]')
      find('input[data-person-details-label]').fill_in(with: 'Fax')
      find('input[data-person-details-value]').fill_in(with: '+49 30 1234568')
    end

    add_button.click
    within(rows[1]) do
      find('select').select(kind_name('address'))
      expect(page).to have_css("textarea[data-person-details-value][maxlength='#{PersonDetail::MAX_ADDRESS_LENGTH}']")
      expect(page).to have_css('input[data-person-details-label][list="person-detail-suggestions-address"]')
      find('input[data-person-details-label]').fill_in(with: 'Büro')
      find('textarea[data-person-details-value]').fill_in(with: "Musterstraße 1\n12345 Berlin")
    end

    add_button.click
    within(rows[2]) do
      find('select').select(kind_name('address'))
      find('select').select(kind_name('url'))
      expect(page).to have_css("input[data-person-details-value][type='url'][maxlength='#{PersonDetail::MAX_VALUE_LENGTH}']")
      find('input[data-person-details-value]').fill_in(with: 'https://example.com')
      click_button remove_label
    end
    expect(rows.size).to eq(2)

    screenshot('people_additional_details_form')
    click_button I18n.t('views.organisations.people.form.save')

    expect(page).to have_text(I18n.t('controllers.people.update.success'))
    expect(lane).to have_link('+49 30 1234568', href: 'tel:+49301234568')
    expect(lane).to have_text('Fax')
    expect(lane).to have_text("Musterstraße 1\n12345 Berlin")
    expect(lane).to have_no_link(href: 'https://example.com')
    expect(page).to have_no_css('[data-controller="person-details"]')
    screenshot('people_additional_details_lane')
    expect(person.reload.additional_details.pluck('label')).to eq(%w[Fax Büro])
  end

  # Review round 1, finding 2: a row added after a removal in the middle
  # needs an index no other row has, or the server merges two rows into one.
  it 'keeps every row when one in the middle was removed before adding' do
    person.update!(additional_details: %w[eins zwei drei].map { |value| { 'kind' => 'text', 'label' => '', 'value' => value } })
    open_form

    within(rows[0]) { click_button remove_label }
    expect(rows.size).to eq(2)
    add_button.click
    within(rows.last) { find('input[data-person-details-value]').fill_in(with: '+49 30 4') }
    click_button I18n.t('views.organisations.people.form.save')

    expect(page).to have_text(I18n.t('controllers.people.update.success'))
    expect(person.reload.additional_details.pluck('value')).to eq(['zwei', 'drei', '+49 30 4'])
  end

  # Review round 2, finding 1: a kind switch emptied a date and lost the line
  # breaks of an address, and the save then dropped the row behind a success.
  it 'keeps what was typed when the kind changes, and names a value that does not fit' do
    person.update!(additional_details: [{ 'kind' => 'address', 'label' => 'Büro', 'value' => "Musterstraße 1\n12345 Berlin" },
                                        { 'kind' => 'text', 'label' => 'Geburtstag', 'value' => 'im Mai' }])
    open_form

    within(rows[0]) do
      find('select').select(kind_name('text'))
      expect(find('input[data-person-details-value]').value).to eq('Musterstraße 1, 12345 Berlin')
    end
    within(rows[1]) do
      find('select').select(kind_name('date'))
      expect(find('[data-person-details-value]').value).to eq('im Mai')
    end
    click_button I18n.t('views.organisations.people.form.save')

    reason = I18n.t('activerecord.errors.models.person.attributes.additional_details.invalid_date', position: 2)
    expect(page).to have_text(reason)
    expect(rows[1].find('[data-person-details-value]').value).to eq('im Mai')
    expect(person.reload.additional_details.pluck('value')).to eq(["Musterstraße 1\n12345 Berlin", 'im Mai'])
  end

  # Review round 2, findings 4 and 5: focus after adding and removing, and the
  # rows named by their position after a removal.
  it 'moves the focus to the new row and back to the add button, and renumbers the rows' do
    open_form
    add_button.click
    add_button.click
    # Review round 3, finding 2: the template's own number is 0-based.
    expect(rows.map { |row| row['aria-label'] })
      .to eq([1, 2].map { |n| I18n.t('views.organisations.people.form.detail_position', position: n) })

    expect(page.evaluate_script('document.activeElement === document.querySelectorAll("[data-person-details-target=list] select")[1]'))
      .to be(true)
    within(rows[0]) { click_button remove_label }

    expect(page.evaluate_script('document.activeElement.dataset.personDetailsTarget')).to eq('add')
    expect(rows.map { |row| row['aria-label'] })
      .to eq([I18n.t('views.organisations.people.form.detail_position', position: 1)])
  end

  it 'hides the add button at ten with a note, and shows it again after a remove' do
    open_form
    hint = I18n.t('views.organisations.people.form.details_limit', count: PersonDetail::MAX)
    expect(page).to have_no_text(hint)

    PersonDetail::MAX.times { add_button.click }

    expect(rows.size).to eq(PersonDetail::MAX)
    expect(page).to have_no_button(I18n.t('views.organisations.people.form.add_detail'))
    expect(page).to have_text(hint)

    within(rows.last) { click_button remove_label }

    expect(rows.size).to eq(PersonDetail::MAX - 1)
    expect(add_button).to be_visible
    expect(page).to have_no_text(hint)
  end

  it 'clears the details when the last one is removed and saved' do
    person.update!(additional_details: [{ 'kind' => 'text', 'label' => 'Erreichbar', 'value' => 'nur vormittags' }])
    open_form
    expect(rows.size).to eq(1)

    within(rows[0]) { click_button remove_label }
    click_button I18n.t('views.organisations.people.form.save')

    expect(page).to have_text(I18n.t('controllers.people.update.success'))
    expect(page).to have_no_css('[data-controller="person-details"]')
    expect(lane).to have_text('Doris Dienstleister')
    expect(lane).to have_no_text('nur vormittags')
    expect(person.reload.additional_details).to eq([])
  end
end
