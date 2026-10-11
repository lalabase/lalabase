# frozen_string_literal: true

require 'rails_helper'

# Guards the GDPR consent requirement at the self-registration collection point
# (Art. 13 transparency). A registration must not succeed without the terms/privacy
# checkbox, and a successful one must leave an auditable acceptance timestamp.
RSpec.describe 'User registration consent', type: :request do
  # The onboarding seed lazily creates the instance-wide "Lalabase" system
  # account on the first registration; pre-creating it keeps the User.count
  # assertions focused on the registrant.
  before { User.system }

  let(:valid_params) do
    {
      user: {
        first_name: 'Ada',
        last_name: 'Lovelace',
        email: 'ada.consent@example.com',
        password: 'password123',
        password_confirmation: 'password123'
      }
      # Trap params: mandatory on every real submission (BotTrapRequestHelpers).
    }.merge(bot_trap_params)
  end

  # The links belong to the OPERATOR of this instance, not to lalabase.com: the
  # core keeps this form because on a fresh self-hosted install it is the only
  # way the first user comes into being, and such an install has no public
  # website of ours behind it (website split, W6).
  describe 'GET /users/sign_up' do
    it 'links terms and privacy to the addresses the operator configured',
       legal_identity: { terms_page_url: 'https://operator.example/agb',
                         privacy_page_url: 'https://operator.example/datenschutz' } do
      get new_user_registration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="user[terms_accepted]"')
      expect(response.body).to include('https://operator.example/agb')
      expect(response.body).to include('https://operator.example/datenschutz')
    end

    # The case every fresh instance is in. A missing address must not swallow the
    # WORD it was attached to, or the sentence reads "I accept the and have read
    # the ." -- consent has to stay legible before it can be given.
    it 'still reads as a sentence on an instance with no legal pages configured',
       legal_identity: {} do
      get new_user_registration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="user[terms_accepted]"')
      expect(response.body).to include(I18n.t('views.shared.consent.terms_link_text'))
      expect(response.body).to include(I18n.t('views.shared.consent.privacy_link_text'))
    end
  end

  describe 'POST /users without the consent checkbox' do
    it 'does not create a user and re-renders the form with an error' do
      # terms_accepted omitted → unchecked
      expect { post user_registration_path, params: valid_params }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('flash.registrations.accept_terms'))
    end

    it 'treats an unchecked ("0") value as no consent' do
      params = valid_params.deep_merge(user: { terms_accepted: '0' })

      expect { post user_registration_path, params: params }.not_to change(User, :count)

      expect(User.find_by(email: 'ada.consent@example.com')).to be_nil
    end
  end

  describe 'POST /users with the consent checkbox' do
    let(:params) { valid_params.deep_merge(user: { terms_accepted: '1' }) }

    it 'creates the user and records the acceptance timestamp' do
      expect { post user_registration_path, params: params }.to change(User, :count).by(1)

      user = User.find_by(email: 'ada.consent@example.com')
      expect(user).to be_present
      expect(user.terms_accepted_at).to be_present
      expect(user.terms_accepted_at).to be_within(1.minute).of(Time.current)
    end

    it 'redirects away from the sign-up form on success' do
      post user_registration_path, params: params

      expect(response).to have_http_status(:redirect)
    end
  end
end
