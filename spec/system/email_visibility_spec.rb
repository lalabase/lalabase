# frozen_string_literal: true

require 'rails_helper'

# With real clicks: a member chooses in the display settings which email the
# others see, and another member then sees exactly that on the members page and
# in the people directory (User::EmailDisplay).
RSpec.describe 'Choosing the email the others see', type: :system do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:lena) { create(:user, first_name: 'Lena', last_name: 'Beispiel', email: 'lena-login@example.com') }
  let(:adele) { create(:user, first_name: 'Adele', last_name: 'Beispiel', email: 'adele@example.com') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    [lena, adele].each { |user| create(:membership, user: user, organisation: organisation, role: role, active: true) }
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def screenshot(name)
    page.execute_script('document.getAnimations().forEach((animation) => animation.finish())')
    directory = Rails.root.join('tmp/screenshots')
    FileUtils.mkdir_p(directory)
    page.driver.browser.save_screenshot(directory.join("#{name}.png").to_s)
  end

  def choose_and_save(choice, address: nil)
    visit display_user_preferences_path
    choose I18n.t("user_preferences.edit.display.email_visibility.#{choice}", email: lena.email)
    fill_in I18n.t('user_preferences.edit.display.email_visibility.contact_label'), with: address if address
    click_button I18n.t('user_preferences.edit.actions.save')
    expect(page).to have_text(I18n.t('user_preferences.settings_updated'))
  end

  it 'shows the contact address to another member, and nothing after choosing none' do
    sign_in lena
    choose_and_save('contact', address: 'lena.team@example.com')
    screenshot('email_visibility_settings')
    expect(lena.reload).to have_attributes(email_visibility: 'contact', contact_email: 'lena.team@example.com')

    sign_out lena
    sign_in adele
    visit organisation_memberships_path(organisation)
    expect(page).to have_text('Lena')
    expect(page).to have_text('lena.team@example.com')
    expect(page).to have_no_text('lena-login@example.com')
    screenshot('email_visibility_members_page')

    visit organisation_people_path(organisation)
    expect(page).to have_text('lena.team@example.com')
    expect(page).to have_no_text('lena-login@example.com')

    sign_out adele
    sign_in lena
    choose_and_save('none')

    sign_out lena
    sign_in adele
    visit organisation_memberships_path(organisation)
    expect(page).to have_text('Lena')
    expect(page).to have_no_text('lena.team@example.com')
    expect(page).to have_no_text('lena-login@example.com')
  end
end
