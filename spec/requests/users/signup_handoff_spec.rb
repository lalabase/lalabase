# frozen_string_literal: true

require 'rails_helper'

# The browser side of the one-time link: what the visitor of the separate
# website sees when they arrive. The rules of the link itself (purpose, two
# minutes, single use) belong to spec/services/signups/handoff_spec.rb.
RSpec.describe 'GET /users/signup_handoff' do
  let(:secret) { SecureRandom.hex(32) }

  around do |example|
    previous = Rails.configuration.x.provisioning
    Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new(secret: secret)
    example.run
  ensure
    Rails.configuration.x.provisioning = previous
  end

  # The whole path a new customer takes: the website posts the signup, the core
  # answers with the link, the browser follows it.
  def sign_up_through_the_website(extra = {})
    post '/api/provisioning/v1/signups',
         params: { signup: { email: 'visitor@example.com', password: 'password123',
                             password_confirmation: 'password123', first_name: 'Vic',
                             last_name: 'Visitor', organisation_name: 'Visitor Organisation',
                             language: 'de', terms_accepted: true }.merge(extra) }.to_json,
         headers: { 'Authorization' => "Bearer #{secret}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body.dig('data', 'signup', 'sign_in_url')
  end

  it 'signs the new customer in and lands them where the form used to' do
    url = sign_up_through_the_website
    user = User.find_by!(email: 'visitor@example.com')

    get url

    expect(response).to redirect_to(organisation_root_path(user.organisations.sole))
    expect(flash[:notice]).to eq(I18n.t('devise.registrations.signed_up'))

    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  # "We will call you" -- NOT "your discount is active". Somebody who ticked the
  # founder box believes they HAVE 50 %; in truth it is a request decided after a
  # phone call. Until 20.09.2026 the core's own form said so after the sign-up
  # (append_founder_signup_notice), and that form was the only place that did.
  # Every customer of ours arrives through THIS link instead, and was told
  # nothing: five details typed in, a discount asked for, and the product
  # answered with a plain welcome. Found when the sentence lost its last reader.
  describe 'a visitor who asked for the new-founder discount' do
    let(:founder_request) do
      { founder_signup: { requested: true, company_name: 'Visitor GmbH', company_seat: 'Kiel',
                          founded_on: 6.months.ago.to_date.iso8601,
                          revenue_band: FounderSignup::REVENUE_BAND_UP_TO_50K,
                          phone: '+49 431 123456' } }
    end

    it 'is told the request arrived and that a call follows' do
      get sign_up_through_the_website(founder_request)

      expect(FounderSignup.sole).to be_open
      expect(flash[:notice]).to include(I18n.t('devise.registrations.signed_up'))
      expect(flash[:notice]).to include(I18n.t('flash.registrations.founder_signup_received'))
    end

    # "We will call you" is wrong for a request that was already answered. The
    # link only lives for two minutes after a sign-up, so this cannot happen by
    # itself today; the example pins the condition so that widening the link's
    # life or reusing the notice elsewhere does not quietly widen the promise.
    it 'is not said once the request has been decided' do
      url = sign_up_through_the_website(founder_request)
      FounderSignup.sole.update_columns(status: FounderSignup::STATUS_DECLINED, decided_at: Time.current)

      get url

      expect(flash[:notice]).to eq(I18n.t('devise.registrations.signed_up'))
    end

    # The sentence is a promise of a phone call. It must not reach somebody who
    # never asked for one.
    it 'is not said to a visitor who did not ask' do
      get sign_up_through_the_website

      expect(flash[:notice]).to eq(I18n.t('devise.registrations.signed_up'))
    end
  end

  it 'refuses a second visit and says so without naming the reason' do
    url = sign_up_through_the_website
    get url
    reset!

    get url

    expect(response).to redirect_to(new_user_session_path)
    expect(flash[:alert]).to eq(I18n.t('flash.signup_handoffs.invalid'))
  end

  # Rails runs the GET action for a HEAD too, so a scanner that only looks at
  # headers would spend the link and the customer's own click would find it used.
  it 'refuses HEAD instead of spending the link on it' do
    url = sign_up_through_the_website

    head url

    expect(response).to have_http_status(:method_not_allowed)
    expect(User.find_by!(email: 'visitor@example.com').last_seen_at).to be_nil

    get url
    expect(response).to redirect_to(organisation_root_path(User.find_by!(email: 'visitor@example.com').organisations.sole))
  end

  it 'sends a made-up token to the sign-in page instead of anywhere else' do
    get users_signup_handoff_path(token: 'made-up')

    expect(response).to redirect_to(new_user_session_path)
    expect(flash[:alert]).to eq(I18n.t('flash.signup_handoffs.invalid'))
  end

  # A session that already exists belongs to somebody. Swapping it behind a link
  # in a URL would be a surprise, so the link is left alone for its owner.
  it 'does not swap an existing session, and leaves the link unused' do
    url = sign_up_through_the_website
    resident = create(:user, :with_organisation)
    sign_in resident

    get url

    expect(response).to redirect_to(organisation_root_path(resident.organisations.sole))
    expect(User.find_by!(email: 'visitor@example.com').last_seen_at).to be_nil

    sign_out resident
    get url
    expect(response).to redirect_to(organisation_root_path(User.find_by!(email: 'visitor@example.com').organisations.sole))
  end
end
