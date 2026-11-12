# frozen_string_literal: true

require 'rails_helper'

# Which email the others see (User::EmailDisplay) is chosen on the account's profile
# tab, next to the profile picture: like the picture it grants nothing, so it is saved
# without the current password (Devise's form of the same tab demands it for every
# change). Login address and password stay behind that gate. Until 2026-11-12 the form
# stood on the preferences page.
RSpec.describe 'Account profile: the email the others see', :ci_guard, type: :request do
  let(:user) { create(:user, email: 'login@example.com', password: 'password123') }

  before { sign_in user }

  def save(**fields)
    patch user_registration_display_path, params: { user: fields }
  end

  it 'offers the three choices and the contact address on the profile tab' do
    get edit_user_registration_path

    expect(response).to have_http_status(:ok)
    User::EmailDisplay::EMAIL_VISIBILITIES.each do |choice|
      expect(response.body).to include(%(value="#{choice}"))
      expect(response.body).to include(CGI.escapeHTML(I18n.t("user_preferences.edit.display.email_visibility.#{choice}",
                                                             email: 'login@example.com')))
    end
    expect(response.body).to include('name="user[contact_email]"')
    expect(response.body).to include('value="login" checked="checked"')
  end

  # The form sends the choice with every save; a wrong preselection would reset a
  # hidden address on the next change of the picture.
  %w[contact none].each do |choice|
    it "preselects #{choice} when the member chose it" do
      user.update!(email_visibility: choice, contact_email: 'team@example.com')

      get edit_user_registration_path

      expect(response.body).to include(%(value="#{choice}" checked="checked"))
      expect(response.body).not_to include('value="login" checked')
    end
  end

  it 'keeps none when the form is saved again with its preselected form values' do
    user.update!(email_visibility: 'none')
    get edit_user_registration_path
    form = Nokogiri::HTML(response.body)
    chosen = form.at_css('input[name="user[email_visibility]"][checked]')['value']

    save(email_visibility: chosen, contact_email: '')

    expect(user.reload.email_visibility).to eq('none')
  end

  it 'saves a contact address without the current password' do
    save(email_visibility: 'contact', contact_email: 'team@example.com')

    expect(response).to redirect_to(edit_user_registration_path(anchor: 'section-display'))
    expect(user.reload).to have_attributes(email_visibility: 'contact', contact_email: 'team@example.com',
                                           email: 'login@example.com')
  end

  it 'saves no email at all and keeps a stored contact address' do
    user.update!(email_visibility: 'contact', contact_email: 'team@example.com')

    save(email_visibility: 'none', contact_email: 'team@example.com')

    expect(user.reload).to have_attributes(email_visibility: 'none', contact_email: 'team@example.com')
  end

  it 'refuses an invalid address and renders the tab with what was typed and the reason' do
    save(email_visibility: 'contact', contact_email: 'team@')

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('user_preferences.edit.display.email_visibility.label'))
    doc = Nokogiri::HTML(response.body)
    form = doc.at_css(%(main form[action="#{user_registration_display_path}"]))
    expect(form.at_css('input[name="user[contact_email]"]')['value']).to eq('team@')
    expect(form.at_css('[role="alert"]').text.squish).to be_present
    expect(user.reload).to have_attributes(email_visibility: 'login', contact_email: nil)
  end

  # The save is tried on a copy of the account. The rest of the tab (the hint under the
  # login address, the other form, the layout) keeps describing the SAVED account: a
  # refused address must not read as the one the others see now.
  it 'keeps the rest of the tab on the saved account after a refused save' do
    save(email_visibility: 'none', contact_email: 'x' * (User::EmailDisplay::MAX_CONTACT_EMAIL_LENGTH + 1))

    expect(response).to have_http_status(:unprocessable_content)
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css('[data-shown-email-hint]').text)
      .to include(I18n.t('views.devise.registrations.edit.shown_email.login', email: 'login@example.com'))
    expect(doc.at_css(%(main form[action="#{user_registration_path}"] [role="alert"]))).to be_nil
    expect(doc.at_css(%(main form[action="#{user_registration_display_path}"] input[value="none"][checked]))).to be_present
    # The refused save answers under its own address; the sidebar still marks the account.
    expect(doc.css('#sidebar a.sidebar-row--active').map { |link| link['href'] }).to eq([edit_user_registration_path])
  end

  it 'refuses the contact choice without an address' do
    save(email_visibility: 'contact', contact_email: '')

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.email_visibility).to eq('login')
  end

  it 'refuses an unknown choice' do
    save(email_visibility: 'public')

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.email_visibility).to eq('login')
  end

  it 'never changes the login address or the password on this path' do
    save(email_visibility: 'none', email: 'other@example.com', password: 'newpassword1', password_confirmation: 'newpassword1')

    expect(user.reload.email).to eq('login@example.com')
    expect(user.valid_password?('password123')).to be(true)
    expect(user.email_visibility).to eq('none')
  end

  # One save for the picture and the choice: a refused choice must not leave a
  # new picture behind under a 422 that says nothing was saved.
  it 'keeps the old picture when the email choice in the same submit is refused' do
    save(avatar: fixture_file_upload('test_avatar.png', 'image/png'), email_visibility: 'contact', contact_email: '')

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.avatar).not_to be_attached
    expect(user.email_visibility).to eq('login')
  end

  it 'leaves the choice alone when the form is saved without it' do
    user.update!(email_visibility: 'none')

    save(remove_avatar: '0')

    expect(user.reload.email_visibility).to eq('none')
  end
end
