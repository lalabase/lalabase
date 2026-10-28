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
    page.driver.browser.save_screenshot(Rails.root.join("tmp/screenshots/#{name}.png").to_s)
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
      expect(page).to have_css('textarea[data-person-details-value]')
      expect(page).to have_css('input[data-person-details-label][list="person-detail-suggestions-address"]')
      find('input[data-person-details-label]').fill_in(with: 'Büro')
      find('textarea[data-person-details-value]').fill_in(with: "Musterstraße 1\n12345 Berlin")
    end

    add_button.click
    within(rows[2]) do
      find('select').select(kind_name('url'))
      expect(page).to have_css('input[data-person-details-value][type="url"]')
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
