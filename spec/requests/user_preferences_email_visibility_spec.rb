# frozen_string_literal: true

require 'rails_helper'

# Which email the others see (User::EmailDisplay) is chosen in the display
# section of the settings, next to the profile picture: like the picture it
# grants nothing, so it is saved without the current password (the Devise
# profile demands it for every change). Login address and password stay behind
# that gate.
RSpec.describe 'User preferences: the email the others see', :ci_guard, type: :request do
  let(:user) { create(:user, email: 'login@example.com', password: 'password123') }

  before { sign_in user }

  def save(**fields)
    patch user_preferences_path, params: { current_section: 'display', user: fields }
  end

  it 'offers the three choices and the contact address in the display section' do
    get display_user_preferences_path

    expect(response).to have_http_status(:ok)
    User::EmailDisplay::EMAIL_VISIBILITIES.each do |choice|
      expect(response.body).to include(%(value="#{choice}"))
      expect(response.body).to include(CGI.escapeHTML(I18n.t("user_preferences.edit.display.email_visibility.#{choice}",
                                                              email: 'login@example.com')))
    end
    expect(response.body).to include('name="user[contact_email]"')
    expect(response.body).to include('value="login" checked="checked"')
  end

  it 'saves a contact address without the current password' do
    save(email_visibility: 'contact', contact_email: 'team@example.com')

    expect(response).to redirect_to(display_user_preferences_path)
    expect(user.reload).to have_attributes(email_visibility: 'contact', contact_email: 'team@example.com',
                                           email: 'login@example.com')
  end

  it 'saves no email at all and keeps a stored contact address' do
    user.update!(email_visibility: 'contact', contact_email: 'team@example.com')

    save(email_visibility: 'none', contact_email: 'team@example.com')

    expect(user.reload).to have_attributes(email_visibility: 'none', contact_email: 'team@example.com')
  end

  it 'refuses an invalid address and renders the section with the reason' do
    save(email_visibility: 'contact', contact_email: 'team@')

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('user_preferences.edit.display.email_visibility.label'))
    expect(response.body).to include('team@')
    expect(user.reload).to have_attributes(email_visibility: 'login', contact_email: nil)
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

  it 'leaves the choice alone when the section is saved without it' do
    user.update!(email_visibility: 'none')

    patch user_preferences_path, params: { current_section: 'display', preferences: { name_display: 'full' } }

    expect(user.reload.email_visibility).to eq('none')
  end
end
