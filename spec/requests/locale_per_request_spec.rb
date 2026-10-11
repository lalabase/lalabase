# frozen_string_literal: true

require 'rails_helper'

# I18n.locale is thread state, and a Puma thread serves one request after the other.
# Until 10.09.2026 ApplicationController only ever SET it (the profile language for a
# signed-in user, the address for a public page) and never put it back. A page without a
# language in its address, seen by someone not signed in (sign-up, sign-in, an
# invitation), came out in whatever language the thread had served last, and the consent
# link on the sign-up form led to the German terms or to their translation by chance.
#
# A request spec runs every request on the test's own thread, which is how the leak was
# measured and why these examples can show it. Where an example needs "another visitor's
# request on this thread", it sets I18n.locale by hand: without that, the leak itself
# would carry the right language over and the example could not fail.
RSpec.describe 'The language of a request', type: :request do
  # An address that carries a language. These used to be the public pricing pages,
  # then the documentation's per-language paths; since D5 the core routes NEITHER
  # (doc/docs_delivery_plan.md), and `/docs/:locale` was the last route in this
  # application with a language in the PATH. The ladder's top rung read exactly
  # that and went with it, so what is left to pin here starts at the query
  # locale, and `?locale=` is part of an address too.
  #
  # ⚠️ Measured while writing this: an example that draws its own
  # locale-prefixed route with `with_routing` does NOT work here. The route did
  # not match, the request answered 404, and the error page that comes back
  # carries `lang="en"` -- Rails' own debug page (consider_all_requests_local in
  # the test environment, and actionpack's rescues/layout.erb starts with
  # `<html lang="en">`), not this application's layout. So the example read a
  # language off a page it never meant to fetch, and was green for the wrong
  # reason, in one case even asserting the opposite of what the code does. If
  # the rung ever comes back, its spec needs a route that ships, and
  # `page_language` alone will not tell it that something went wrong: assert the
  # status too.
  let(:english_page) { new_user_session_path(locale: :en) }
  let(:german_page) { new_user_session_path(locale: :de) }

  def page_language
    Nokogiri::HTML(response.body).at_css('html')['lang']
  end

  # What another visitor's request used to leave on this thread.
  def thread_left_in(locale)
    I18n.locale = locale
  end

  it 'hands the thread back in the default language' do
    get english_page

    expect(I18n.locale).to eq(I18n.default_locale)
  end

  it 'gives a new visitor German on a page without a language in its address' do
    get english_page
    reset! # a second visitor on the same thread

    get new_user_registration_path

    expect(page_language).to eq('de')
  end

  describe 'explicit locale selection' do
    it 'uses a valid query locale and remembers it for the next Devise page' do
      get new_user_session_path, params: { locale: 'en' }

      expect(page_language).to eq('en')

      get new_user_password_path

      expect(response).to have_http_status(:ok)
      expect(page_language).to eq('en')
    end

    it 'ignores an unsupported query locale' do
      get new_user_session_path, params: { locale: 'xx' }

      expect(page_language).to eq('de')
    end

    it 'lets a valid query locale win over the signed-in profile' do
      sign_in create(:user, language_preference: 'de')

      get language_user_preferences_path, params: { locale: 'en' }

      expect(page_language).to eq('en')
    end
  end

  describe 'browser language selection' do
    it 'uses a supported regional language with the highest quality' do
      get new_user_session_path,
          headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr-FR, en-GB;q=0.9, de;q=0.7' }

      expect(page_language).to eq('en')
    end

    # English is the only supported language in the header, so without the q=0 rule the
    # page would come out English.
    it 'ignores a language whose quality is zero' do
      get new_user_session_path,
          headers: { 'HTTP_ACCEPT_LANGUAGE' => 'fr, en;q=0' }

      expect(page_language).to eq('de')
    end

    it 'survives malformed and out-of-range quality values' do
      get new_user_session_path,
          headers: { 'HTTP_ACCEPT_LANGUAGE' => 'en;q=abc, en-US;q=2, de;q=0.5' }

      expect(response).to have_http_status(:ok)
      expect(page_language).to eq('de')
    end

    it 'prefers the earlier entry at equal quality, whatever its case' do
      get new_user_session_path, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'EN-us, de' }

      expect(page_language).to eq('en')
    end

    # Decided in the review of #816 (14.09.2026): the account starts in the language its
    # form was shown in, also when only the browser asked for it. The column defaults to
    # German, so this example fails if Accept-Language stops reaching the profile.
    it 'gives an account signed up from an English browser English as its profile language' do
      User.system
      params = {
        user: {
          first_name: 'Grace', last_name: 'Hopper', email: 'grace.browser@example.com',
          password: 'password123', password_confirmation: 'password123', terms_accepted: '1'
        }
      }.merge(bot_trap_params)

      post user_registration_path, params: params, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'en-GB,en;q=0.9' }

      expect(User.find_by(email: 'grace.browser@example.com')&.language_preference).to eq('en')
    end

    it 'keeps a remembered public locale ahead of the browser language' do
      get english_page

      get new_user_session_path, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'de' }

      expect(page_language).to eq('en')
    end

    it 'keeps a signed-in profile ahead of the browser language' do
      sign_in create(:user, language_preference: 'de')

      get language_user_preferences_path, headers: { 'HTTP_ACCEPT_LANGUAGE' => 'en' }

      expect(page_language).to eq('de')
    end
  end

  context 'when an anonymous visitor has been reading the English pages' do
    before do
      get english_page
      thread_left_in(:de)
    end

    it 'shows the sign-up form in English, with the configured terms behind the consent link',
       legal_identity: { terms_page_url: 'https://operator.example/en/terms' } do
      get new_user_registration_path

      expect(page_language).to eq('en')
      expect(response.body).to include('href="https://operator.example/en/terms"')
    end

    it 'follows the visitor back to German' do
      get german_page
      thread_left_in(:en)

      get new_user_registration_path

      expect(page_language).to eq('de')
    end

    # Devise translates this message in the language current when authenticate_user!
    # runs, so the language has to be settled before that callback. The page matters: its
    # controller must inherit authenticate_user! from ApplicationController without
    # declaring it again. A controller that declares it itself (UserPreferencesController,
    # in the first version of this example) moves the callback behind switch_locale, and
    # the example stayed green whatever order ApplicationController kept.
    it 'asks them in English to sign in first' do
      get select_organisation_path

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.unauthenticated', locale: :en))
    end

    # Without this, English would last exactly until the sign-up: the column defaults to
    # German, and the first page after the form would switch the visitor over.
    it 'gives the account they sign up for English as its profile language' do
      User.system
      params = {
        user: {
          first_name: 'Ada', last_name: 'Lovelace', email: 'ada.locale@example.com',
          password: 'password123', password_confirmation: 'password123', terms_accepted: '1'
        }
      }.merge(bot_trap_params)

      post user_registration_path, params: params

      expect(User.find_by(email: 'ada.locale@example.com')&.language_preference).to eq('en')
    end
  end

  # The profile answers for a signed-in user, not the last public page: someone who chose
  # German and glanced at /en/pricing keeps a German application.
  it 'answers a signed-in user in the profile language, whatever public page came before' do
    sign_in create(:user, language_preference: 'de')
    get english_page
    thread_left_in(:en)

    get language_user_preferences_path

    expect(response.body).to include(I18n.t('user_preferences.language.interface_description', locale: :de))
  end
end
