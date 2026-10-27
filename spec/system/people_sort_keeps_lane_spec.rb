# frozen_string_literal: true

require 'rails_helper'

# Review of PR #51: the column heads of the people list are rendered with the
# selection of the page request. A row click changes the open person in the
# address and reloads only the lane, so only the browser shows whether a sort
# keeps the person open NOW (layout_toggle#syncFilterContext, data-lane-keep).
RSpec.describe 'People list sort keeps the open person', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:person, organisation: organisation, name: 'Berta Erste')
    create(:person, organisation: organisation, name: 'Clara Zweite')
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane
    find("turbo-frame##{Organisations::PeopleController::DETAIL_FRAME_ID}")
  end

  it 'sorts with the person opened by a row click, not the one the page was loaded with' do
    berta = Person.find_by!(name: 'Berta Erste')
    clara = Person.find_by!(name: 'Clara Zweite')
    visit organisation_people_path(organisation, person_id: berta.id)
    expect(lane).to have_text('Berta Erste')

    find('.people-row', text: 'Clara Zweite').click
    expect(page).to have_current_path(/person_id=#{clara.id}/)
    expect(lane).to have_text('Clara Zweite')

    click_link I18n.t('views.organisations.people.index.columns.last')

    expect(page).to have_current_path(/sort=last/)
    expect(page).to have_current_path(/person_id=#{clara.id}/)
    expect(lane).to have_text('Clara Zweite')
  end

  it 'sorts without a person once the lane was closed' do
    berta = Person.find_by!(name: 'Berta Erste')
    visit organisation_people_path(organisation, person_id: berta.id)
    expect(lane).to have_text('Berta Erste')

    find('body').send_keys(:escape)
    expect(page).to have_no_current_path(/person_id=/)

    click_link I18n.t('views.organisations.people.index.columns.last')

    expect(page).to have_current_path(/sort=last/)
    expect(page).to have_no_current_path(/person_id=/)
  end
end
