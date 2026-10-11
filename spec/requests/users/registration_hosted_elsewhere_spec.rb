# frozen_string_literal: true

require 'rails_helper'

# When an operator runs the public pages as a separate program (website split),
# self-registration lives there and GET /users/sign_up must send people to it.
# Without that, W5 leaves TWO sign-up forms answering on the same domain: the
# website's and this one, each with its own bot trap and its own copy.
#
# Off unless LALABASE_SIGNUP_URL is set. The core is open source and a
# self-hosted instance has no second program, so the default has to be the form
# this controller has always rendered.
RSpec.describe 'Sign-up hosted elsewhere', type: :request do
  let(:elsewhere) { 'https://lalabase.com/signup' }

  def with_signup_url(value)
    previous = Rails.application.config.x.signup_location
    Rails.application.config.x.signup_location = Lalabase::SignupLocation.new(url: value)
    yield
  ensure
    Rails.application.config.x.signup_location = previous
  end

  context 'without a configured location' do
    it 'renders this instance own form, exactly as before' do
      with_signup_url(nil) do
        get new_user_registration_path

        expect(response).to have_http_status(:ok)
      end
    end
  end

  context 'with a configured location' do
    it 'sends a visitor there' do
      with_signup_url(elsewhere) do
        get new_user_registration_path

        expect(response).to redirect_to(elsewhere)
      end
    end

    # 301 outlives unsetting the variable: a browser keeps redirecting after the
    # operator has changed their mind, and rolling the switch back is the whole
    # fallback plan of the move.
    it 'redirects temporarily, so the switch can be rolled back' do
      with_signup_url(elsewhere) do
        get new_user_registration_path

        expect(response).to have_http_status(:found)
      end
    end

    # The other program's form cannot redeem a token -- the provisioning call
    # has no field for one. An invited guest sent there would land on a form
    # that creates a NEW organisation instead of joining the inviting one.
    it 'keeps an invited guest here, because only this form can redeem a token' do
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) { create(:invitation, organisation: organisation) }

      with_signup_url(elsewhere) do
        get new_user_registration_path(token: invitation.token)

        expect(response).to have_http_status(:ok)
      end
    end

    # A closed instance says so rather than sending people to a form that would
    # refuse them at the end.
    it 'still answers a closed instance with its own notice' do
      SystemSetting.set('allow_registration', false)

      with_signup_url(elsewhere) do
        get new_user_registration_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(elsewhere)
      end
    end
  end

  # A typo must leave the instance working rather than send people nowhere, and
  # a relative or javascript: value must never become the public sign-up.
  describe 'a value that is not an absolute http(s) URL' do
    ['/signup', 'javascript:alert(1)', 'lalabase.com/signup', ' '].each do |bad|
      it "ignores #{bad.inspect} and keeps serving this form" do
        with_signup_url(bad) do
          get new_user_registration_path

          expect(response).to have_http_status(:ok)
        end
      end
    end
  end
end
