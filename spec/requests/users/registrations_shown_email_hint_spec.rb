# frozen_string_literal: true

require 'rails_helper'

# The account page shows the login address, and that field is where a member
# asks who else sees it. The answer below the field follows the member's own
# choice (User::EmailDisplay), and the link leads to the page that changes it.
# Also pins the two names: "Account" for this page, "Profil" for the page that
# holds the picture and the shown email.
RSpec.describe 'Account page: who sees the email', type: :request do
  let(:user) { create(:user, email: 'login@example.com') }

  before { sign_in user }

  def hint_html
    get edit_user_registration_path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).at_css('[data-shown-email-hint]')
  end

  it 'says that others see the login address, and links to the page that changes it' do
    hint = hint_html

    expect(hint.text).to include(I18n.t('views.devise.registrations.edit.shown_email.login'))
    expect(hint.at_css('a')['href']).to eq(display_user_preferences_path)
    expect(hint.at_css('a').text).to eq(I18n.t('views.devise.registrations.edit.shown_email.change'))
  end

  it 'names the other address when the member shows one' do
    user.update!(email_visibility: 'contact', contact_email: 'contact@example.com')

    hint = hint_html

    expect(hint.text).to include(I18n.t('views.devise.registrations.edit.shown_email.contact',
                                        email: 'contact@example.com'))
    expect(hint.text).to include('contact@example.com')
    expect(hint.at_css('a')['href']).to eq(display_user_preferences_path)
  end

  it 'says that others see no email when the member shows none' do
    user.update!(email_visibility: 'none')

    hint = hint_html

    expect(hint.text).to include(I18n.t('views.devise.registrations.edit.shown_email.none'))
    expect(hint.text).not_to include('login@example.com')
    expect(hint.at_css('a')['href']).to eq(display_user_preferences_path)
  end

  it 'has the hint in both languages' do
    %i[de en].each do |locale|
      %w[login contact none change].each do |key|
        expect(I18n.exists?("views.devise.registrations.edit.shown_email.#{key}", locale, fallback: false))
          .to be(true), "#{locale}: #{key}"
      end
    end
  end

  it 'calls the page Account and the display settings Profil' do
    expect(I18n.t('navigation.profile', locale: :de)).to eq('Account')
    expect(I18n.t('navigation.profile', locale: :en)).to eq('Account')
    expect(I18n.t('views.devise.registrations.edit.title', locale: :de)).to eq('Account')
    expect(I18n.t('views.devise.registrations.edit.title', locale: :en)).to eq('Account')
    expect(I18n.t('navigation.settings_display', locale: :de)).to eq('Profil')
    expect(I18n.t('navigation.settings_display', locale: :en)).to eq('Profile')
    expect(I18n.t('user_preferences.edit.display.title', locale: :de)).to eq('Profil')
    expect(I18n.t('user_preferences.edit.display.title', locale: :en)).to eq('Profile')
  end
end
