# frozen_string_literal: true

require 'rails_helper'

# Devise builds the sign-in failure message itself, in the FailureApp, and interpolates
# %{authentication_keys} from User.human_attribute_name(:email). devise 5.0 lowercases the
# first letter of that name ("E-Mail" becomes "e-Mail", "Email" becomes "email") and only
# restores the capital when the message STARTS with it. Ours does not, so the German text
# would have read "Ungültige e-Mail oder Passwort." after the upgrade. The locale files now
# spell the message out without the placeholder; this spec pins both languages so the
# wording no longer depends on how Devise cases an attribute name.
RSpec.describe 'Sign-in failure message', type: :request do
  let!(:user) { create(:user, email: 'known@example.com') }

  # The sign-in form has no language in its address. ?locale= on the form picks one and the
  # session keeps it for the POST (spec/requests/locale_per_request_spec.rb); the public
  # pages that used to set it here leave the core in step W6 of the website split. Until
  # 10.09.2026 this spec set the test thread's locale instead and relied on the request
  # inheriting it, which was the very leak that gave real visitors a random language.
  def attempt(email, locale)
    get new_user_session_path(locale: locale)
    post user_session_path, params: { user: { email: email, password: 'wrong-password' } }
  end

  it 'reads "Ungültige E-Mail oder Passwort." in German for a wrong password' do
    attempt(user.email, :de)
    expect(flash[:alert]).to eq('Ungültige E-Mail oder Passwort.')
  end

  it 'reads the same German sentence for an unknown address' do
    attempt('nobody@example.com', :de)
    expect(flash[:alert]).to eq('Ungültige E-Mail oder Passwort.')
  end

  it 'reads "Invalid email or password." in English' do
    attempt(user.email, :en)
    expect(flash[:alert]).to eq('Invalid email or password.')
  end
end
