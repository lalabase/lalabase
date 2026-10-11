# frozen_string_literal: true

require 'rails_helper'

# Two hardening seams on the public sign-up that carry no user-visible feature
# but each turned an unauthenticated request into a 500 or leaked a form the
# instance was not showing:
#
#   1. attacker-controlled SHAPE of the params (user=x, user[]=x, token[a]=1),
#      which used to reach Hash#dig / find_by and raise;
#   2. the bot trap firing on a closed instance, answering a fake success or
#      re-rendering the full sign-up form #new never shows when registration is
#      off.
RSpec.describe 'Sign-up request-shape hardening', type: :request do
  before { User.system }

  let(:valid_user) do
    {
      first_name: 'Otto', last_name: 'Neuling',
      email: 'otto.neu@example.com',
      password: 'password123', password_confirmation: 'password123',
      terms_accepted: '1'
    }
  end

  # The new-founder discount left this form on 20.09.2026: it is OUR sales
  # programme, and after W5 only foreign instances and invited people reach the
  # core's sign-up. The request now arrives solely through Api::Provisioning
  # from the website, into the same actor.
  #
  # What this pins is the seam, not the copy (the copy is held by
  # spec/architecture/app_operator_claims_guard_spec.rb): founder params that
  # somebody still posts here must be ignored, not stored, and not raise -- the
  # controller used to read user[founder], whose SHAPE is attacker-controlled.
  describe 'founder params after the discount left this form' do
    it 'registers the user and records no request' do
      params = {
        user: valid_user.merge(founder_signup_requested: '1',
                               founder: { company_name: 'Neuling GmbH', company_seat: 'Kiel',
                                          founded_on: '2026-01-01', phone: '+49 431 1',
                                          revenue_band: FounderSignup::REVENUE_BANDS.first })
      }.merge(bot_trap_params)

      expect { post user_registration_path, params: params }.not_to change(FounderSignup, :count)

      expect(User.find_by(email: valid_user[:email])).to be_present
    end

    # Each shape gets its own example: a successful registration signs the
    # visitor in, and Devise refuses the second POST on the same session with
    # "you are already signed in" -- which would look like the shape guard
    # working when it is only the session talking.
    { 'a scalar' => 'x', 'an array' => ['x'] }.each do |name, shape|
      it "ignores #{name} instead of raising" do
        params = { user: valid_user.merge(founder: shape) }.merge(bot_trap_params)

        post user_registration_path, params: params

        # The shape used to reach Hash#merge on a String. What proves it no
        # longer does is that the registration completed at all.
        expect(User.find_by(email: valid_user[:email])).to be_present
        expect(FounderSignup.count).to eq(0)
      end
    end
  end

  describe 'attacker-controlled param shape' do
    # A scalar `user` used to raise TypeError (String has no #dig) at
    # terms_accepted? BEFORE any guard -- an unauthenticated 500. It must now
    # degrade to the ordinary consent rejection, never a crash.
    it 'answers a scalar user param with a 422, not a 500' do
      post user_registration_path, params: { user: 'x' }.merge(bot_trap_params)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'answers an array user param with a 422, not a 500' do
      post user_registration_path, params: { user: ['x'] }.merge(bot_trap_params)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # A hash token passes the old blank? guard and then blows up find_by with
    # "can't cast ActionController::Parameters" on GET -- a path the post-only
    # registrations/ip throttle does not cover. to_s makes it match nothing.
    it 'renders the sign-up form for a hash-shaped token instead of 500' do
      get new_user_registration_path, params: { token: { a: '1' } }

      expect(response).to have_http_status(:ok)
    end

    it 'renders the sign-up form for an array-shaped token instead of 500' do
      get new_user_registration_path, params: { token: ['1'] }

      expect(response).to have_http_status(:ok)
    end

    # "\0".blank? is false, so the shape guard's to_s let a null byte through to
    # find_by, which the pg adapter refuses to bind ("string contains null byte")
    # -- an unauthenticated 500 on GET. delete("\0") makes it match nothing.
    it 'renders the sign-up form for a NUL-byte token instead of 500' do
      get new_user_registration_path, params: { token: "\u0000" }

      expect(response).to have_http_status(:ok)
    end

    # Consent given as an array must NOT satisfy the gate: Boolean.cast(["1"]) is
    # true, so an array terms_accepted would have registered a user who never
    # ticked the box. user_form_scalar collapses the array to nil first.
    it 'rejects consent submitted as an array value' do
      post user_registration_path,
           params: { user: valid_user.merge(terms_accepted: ['1']) }.merge(bot_trap_params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(User.exists?(email: valid_user[:email])).to be(false)
    end
  end

  # With registration closed, the closed-check now runs BEFORE the bot trap, so
  # neither trap branch can act on an instance that does not register anyone.
  describe 'when registration is closed' do
    before do
      allow(SystemSetting).to receive(:allow_registration?).and_return(false)
      allow(SystemSetting).to receive(:registration_disabled_message).and_return('Registrierung geschlossen.')
    end

    # A filled honeypot must NOT get the fake "welcome, you registered" success
    # on a closed instance; it gets sent back to the (disabled) sign-up page.
    it 'does not fake success for a honeypot hit' do
      post user_registration_path,
           params: valid_user.merge(bot_trap_params).merge(BotTrapProtected::HONEYPOT_FIELD => 'http://spam.example')

      expect(response).to redirect_to(new_user_registration_path)
      expect(response).not_to have_http_status(:see_other)
    end

    # A missing timestamp must NOT re-render the full sign-up form (with
    # user[password]) on a closed instance -- #new renders registration_disabled.
    it 'does not leak the sign-up form for a bad timestamp' do
      post user_registration_path, params: valid_user

      expect(response).to redirect_to(new_user_registration_path)
      expect(response.body).not_to include('name="user[password]"')
    end

    it 'writes no user in either case' do
      post user_registration_path,
           params: valid_user.merge(BotTrapProtected::HONEYPOT_FIELD => 'http://spam.example')

      expect(User.exists?(email: 'otto.neu@example.com')).to be(false)
    end
  end
end
