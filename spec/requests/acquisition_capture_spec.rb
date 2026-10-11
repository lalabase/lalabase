# frozen_string_literal: true

require 'rails_helper'

# What: the whole chain from an anonymous first page view to a frozen origin on
#       the account (doc/akquise_herkunft.md).
# Type: Request spec, because the session is the store -- the rule lives in the
#       interaction of two requests and cannot be seen in a unit test.
# Why:  Three properties fail SILENTLY and each one would leave the evaluation
#       looking healthy while it lies: a later page overwriting the entry point,
#       an INVITED colleague counting as a new customer, and the session not
#       being cleared so a second signup from the same browser inherits the
#       first one's origin.
# Until W6 the entry pages were the public marketing pages. They now live in
# gboyke/lalabase-website; what a self-hoster shows without sign-in is the login,
# the legal pages and the docs, and the capture still applies because the
# registration in the core reads it.
RSpec.describe 'Acquisition capture', type: :request do
  let(:signup_params) do
    {
      user: {
        first_name: 'Otto', last_name: 'Neuling',
        email: 'otto.neu@example.com', password: 'password123',
        password_confirmation: 'password123', terms_accepted: '1'
      }
      # Trap params: mandatory on every real submission (BotTrapRequestHelpers).
    }.merge(bot_trap_params)
  end

  before { User.system }

  def registered_account(email: 'otto.neu@example.com')
    User.find_by(email: email).organisations.first&.account
  end

  it 'freezes the declared origin of the first page onto the account' do
    get root_path, params: { ref: 'redmine-mail-01', utm_source: 'linkedin' }
    post user_registration_path, params: signup_params

    acquisition = registered_account.acquisition

    expect(acquisition).to include('ref' => 'redmine-mail-01', 'utm_source' => 'linkedin')
    expect(acquisition['landing_path']).to eq(root_path)
  end

  it 'keeps the FIRST page, not the one the visitor registered from' do
    get root_path, params: { ref: 'erste-quelle' }
    get new_user_session_path, params: { ref: 'zweite-quelle' }
    post user_registration_path, params: signup_params

    acquisition = registered_account.acquisition

    expect(acquisition['ref']).to eq('erste-quelle')
    expect(acquisition['landing_path']).to eq(root_path)
  end

  it 'records a visitor who declared nothing, with the entry page' do
    get new_user_session_path
    post user_registration_path, params: signup_params

    expect(registered_account.acquisition).to include('landing_path' => new_user_session_path)
    expect(registered_account.acquisition).not_to have_key('ref')
  end

  it 'does NOT attribute an invited colleague, who belongs to a customer already won' do
    organisation = create(:organisation)
    # Invitation is tenant-scoped; only the setup needs the tenant, the
    # registration request itself runs without one.
    invitation = ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: 'kollege@example.com')
    end

    get root_path, params: { ref: 'redmine-mail-01' }
    params = signup_params.deep_merge(user: { email: 'kollege@example.com' })
                          .merge(token: invitation.token)
    post user_registration_path, params: params

    expect(organisation.reload.account.acquisition).to be_nil
  end

  it 'clears the session so a second signup does not inherit the first origin' do
    get root_path, params: { ref: 'einmalig' }
    post user_registration_path, params: signup_params
    expect(registered_account.acquisition['ref']).to eq('einmalig')

    delete destroy_user_session_path
    post user_registration_path,
         params: signup_params.deep_merge(user: { email: 'zweite@example.com' })

    second = registered_account(email: 'zweite@example.com')
    expect(second.acquisition&.dig('ref')).to be_nil
  end

  it 'does not record a signed-in user browsing a public page' do
    user = create(:user)
    sign_in user

    get root_path, params: { ref: 'sollte-nicht-zaehlen' }

    expect(session[:acquisition]).to be_nil
  end

  it 'never lets a broken capture take the registration down' do
    allow(AcquisitionSource).to receive(:from_stored).and_raise(StandardError, 'boom')

    get root_path, params: { ref: 'egal' }
    expect { post user_registration_path, params: signup_params }.to change(User, :count).by(1)

    expect(registered_account).to be_present
  end
end
