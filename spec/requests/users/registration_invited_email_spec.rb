# frozen_string_literal: true

require 'rails_helper'

# The sign-up form through an invitation link. The server always registers the
# invited address (Users::RegistrationsController#build_resource), so the form
# must not offer an input for it: a visitor who typed another address would get
# an account under the invited one without being told.
#
# The page asks the same question the server does (valid_invitation), so an
# expired or used token falls back to the ordinary, editable field.
RSpec.describe 'Sign-up form through an invitation link', type: :request do
  let(:organisation) { create(:organisation) }
  let(:invitation) do
    ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: 'Otto.Neu@Example.com')
    end
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def email_input
    page.at_css('input[name="user[email]"]')
  end

  describe 'with a redeemable invitation' do
    before { get new_user_registration_path(token: invitation.token) }

    it 'shows the invited address as text, not as an input' do
      expect(response).to have_http_status(:ok)
      expect(page.at_css('.lp-field-static')&.text).to eq('otto.neu@example.com')
      expect(response.body).to include(I18n.t('devise.registrations.new.invited_email_hint'))
      expect(email_input).to be_nil
    end

    it 'names the login for password managers without sending it' do
      username = page.at_css('input[autocomplete="username"]')

      expect(username['value']).to eq('otto.neu@example.com')
      expect(username['name']).to be_nil
      expect(username).to have_attribute('hidden')
    end
  end

  it 'registers the invited address from the form as it is sent (no email param)' do
    params = {
      token: invitation.token,
      user: { first_name: 'Otto', last_name: 'Neuling', password: 'password123', terms_accepted: '1' }
    }.merge(bot_trap_params)

    post user_registration_path, params: params

    user = User.find_by(email: 'otto.neu@example.com')
    expect(user).to be_present
    expect(user.organisations).to include(organisation)
  end

  it 'keeps the editable field when the invitation has expired' do
    ActsAsTenant.with_tenant(organisation) { invitation.update!(sent_at: 10.days.ago) }

    get new_user_registration_path(token: invitation.token)

    expect(email_input).to be_present
    expect(page.at_css('.lp-field-static')).to be_nil
  end

  it 'keeps the editable field without a token' do
    allow(SystemSetting).to receive(:allow_registration?).and_return(true)

    get new_user_registration_path

    expect(email_input).to be_present
  end
end
