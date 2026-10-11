# frozen_string_literal: true

require 'rails_helper'

# The bot trap on the public sign-up form (BotTrapProtected,
# doc/bot_registrierungen_plan.md S1). Two independent checks, and the two
# rejection styles are a deliberate, load-bearing difference:
#
#   honeypot  -> pretend success, so the sender learns nothing
#   timestamp -> visible 422, so a wrongly caught human can retry
#
# Every example asserts BOTH that no user was written AND that no mail went out.
# The mail is the actual damage a bot signup does (bounces on a young sending
# domain); a spec that only counted users would stay green if the trap ever
# started rejecting after the mail was queued.
RSpec.describe 'Sign-up bot trap', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { User.system }

  let(:signup_fields) do
    {
      user: {
        first_name: 'Otto',
        last_name: 'Neuling',
        email: 'otto.neu@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        terms_accepted: '1'
      }
    }
  end

  def signup_exists?
    User.exists?(email: 'otto.neu@example.com')
  end

  describe 'the rendered form' do
    it 'carries both trap fields' do
      get new_user_registration_path

      expect(response.body).to include("name=\"#{BotTrapProtected::HONEYPOT_FIELD}\"")
      expect(response.body).to include("name=\"#{BotTrapProtected::TIMESTAMP_FIELD}\"")
    end

    # The trap is worthless if the honeypot is visible, and a visible field on a
    # sign-up form is a bug a reviewer would never think to look for.
    it 'hides the honeypot behind the off-screen class, not with display:none' do
      get new_user_registration_path

      expect(response.body).to include('class="bot-trap"')
      expect(response.body).not_to match(/bot-trap[^>]*style=/)
    end

    # The ONLY example that couples the rendered token to the verdict. Every
    # other spec mints its own token via BotTrapRequestHelpers, which
    # re-implements the generator: if generate and verify ever diverge (payload
    # type, purpose, expiry), those stay green while EVERY real human signup is
    # rejected. This posts back the exact value the app rendered.
    it 'accepts a signup carrying the exact timestamp the form rendered' do
      get new_user_registration_path
      rendered = response.body[/name="#{BotTrapProtected::TIMESTAMP_FIELD}"[^>]*value="([^"]+)"/, 1]
      expect(rendered).to be_present

      # The token reads "now"; jump just past MINIMUM_FILL_SECONDS so the age is
      # a pass without waiting real wall-clock time.
      travel_to(BotTrapProtected::MINIMUM_FILL_SECONDS.seconds.from_now + 1.second) do
        post user_registration_path, params: signup_fields.merge(BotTrapProtected::TIMESTAMP_FIELD => rendered)
      end

      expect(signup_exists?).to be(true)
    end
  end

  # The class name in the markup only hides the field if the rule exists AND the
  # stylesheet holding it actually reaches this page. Both have failed silently
  # in this codebase before, and a visible honeypot on the sign-up form catches
  # customers, not bots.
  describe 'the wiring that makes the honeypot invisible' do
    it 'defines the rule in views.css and pulls views.css into application.css' do
      views_css = Rails.root.join('app/assets/stylesheets/views.css').read
      application_css = Rails.root.join('app/assets/stylesheets/application.css').read

      expect(views_css).to match(/^\.bot-trap \{/)
      expect(views_css).to match(/left:\s*-\d{4,}px/)
      expect(application_css).to match(/require views\b/)
    end

    it 'loads application.css on the sign-up layout' do
      get new_user_registration_path

      expect(response.body).to match(%r{href="[^"]*/application[^"]*\.css"})
    end
  end

  describe 'a filled honeypot' do
    let(:params) do
      signup_fields.merge(bot_trap_params).merge(BotTrapProtected::HONEYPOT_FIELD => 'http://spam.example')
    end

    it 'creates nothing and sends nothing' do
      expect { post user_registration_path, params: params }
        .not_to change(ActionMailer::Base.deliveries, :count)

      expect(signup_exists?).to be(false)
    end

    # Indistinguishable from a real unconfirmed signup: same flash, same
    # status, same SHAPE of redirect target. Status and Location are compared
    # because both were once real fingerprints (302 vs Devise's 303, root vs
    # the fresh organisation) -- the redirect is the channel a script actually
    # looks at. The org id itself is random per signup, so the comparison is
    # on the pattern, not the value. Known, accepted delta: the real response
    # carries a session cookie, the trapped one does not.
    it 'answers exactly like a successful unconfirmed registration' do
      post user_registration_path, params: params
      trapped_flash = flash[:notice]
      trapped_status = response.status
      trapped_location = response.location

      post user_registration_path, params: signup_fields.merge(bot_trap_params)

      expect(response).to have_http_status(:redirect)
      expect(trapped_flash).to eq(flash[:notice])
      expect(trapped_status).to eq(response.status)

      org_root = %r{/org/[0-9a-f-]{36}\z}
      expect(response.location).to match(org_root)
      expect(trapped_location).to match(org_root)
    end

    # The no-grace branch of bot_trap_pretend_success is dead with the current
    # config (allow_unconfirmed_access_for = 3.days), yet open item #1 is to drop
    # the grace period. Without this pin the derivation the comment calls
    # load-bearing is only ever proven on one side, and shipping grace=0 would
    # silently expose the :signed_up_but_unconfirmed / root-redirect branch
    # untested. Compared against a REAL registration under the same stub, so it
    # cannot pass by hard-coding what the trap happens to emit today.
    it 'mimics a real registration on the no-grace path too' do
      allow(User).to receive(:allow_unconfirmed_access_for).and_return(0.days)

      post user_registration_path, params: params
      trapped_flash = flash[:notice]
      trapped_status = response.status
      trapped_location = response.location

      post user_registration_path, params: signup_fields.merge(bot_trap_params)

      expect(trapped_status).to eq(response.status)
      expect(trapped_flash).to eq(flash[:notice])
      expect(trapped_location).to eq(response.location)
      expect(trapped_location).to end_with(root_path)
    end

    # The honeypot is checked BEFORE the timestamp (bot_trap_verdict returns
    # :honeypot first), and that ordering is what makes a scripted fill get the
    # SILENT pretend-success. The likeliest real bot shape is a filled honeypot
    # with no timestamp at all; if the two checks were reordered it would receive
    # the visible 422 and learn it was caught -- exactly what the split prevents.
    # No timestamp is sent here on purpose.
    it 'takes the honeypot branch even when no timestamp is present' do
      post user_registration_path,
           params: signup_fields.merge(BotTrapProtected::HONEYPOT_FIELD => 'http://spam.example')

      expect(response).to have_http_status(:see_other)
      expect(signup_exists?).to be(false)
    end

    # The one production-visible trace of the pretend-success branch. Deleting
    # log_bot_trap (or breaking its interpolation) is otherwise invisible: a
    # working trap and a broken one both answer with the fake success page.
    it 'logs the blocked verdict' do
      allow(Rails.logger).to receive(:warn)

      post user_registration_path, params: params

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/\[BotTrap\] blocked verdict=honeypot/))
    end
  end

  describe 'the timestamp' do
    it 'rejects a submission with no timestamp at all' do
      expect { post user_registration_path, params: signup_fields }
        .not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('flash.bot_trap.rejected'))
      expect(signup_exists?).to be(false)
    end

    it 'rejects a forged timestamp' do
      post user_registration_path,
           params: signup_fields.merge(BotTrapProtected::TIMESTAMP_FIELD => 10.seconds.ago.to_i.to_s)

      expect(response).to have_http_status(:unprocessable_content)
      expect(signup_exists?).to be(false)
    end

    # Frozen clock: the token is signed in the spec process and judged in the
    # controller, and on a slow CI worker more than MINIMUM_FILL_SECONDS can
    # pass between the two -- the expected 422 would become a success.
    it 'rejects a submission faster than a human can type' do
      travel_to(Time.current) do
        post user_registration_path, params: signup_fields.merge(bot_trap_params(rendered_seconds_ago: 0))
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(signup_exists?).to be(false)
    end

    # A scanner's emptiest probe: no user hash, no trap params. Devise falls
    # back to empty params (ParameterSanitizer#default_params), so the reject
    # branch must render the friendly 422, not crash.
    it 'rejects a POST without any user hash at all' do
      expect { post user_registration_path }
        .not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # Backdating the signed value is the obvious attack on "too fast": sign a
    # moment far in the future and the age goes negative.
    it 'rejects a timestamp from the future' do
      post user_registration_path, params: signup_fields.merge(bot_trap_params(rendered_seconds_ago: -600))

      expect(response).to have_http_status(:unprocessable_content)
      expect(signup_exists?).to be(false)
    end

    it 'rejects a form left open longer than the maximum age' do
      stale = BotTrapProtected::MAXIMUM_FORM_AGE + 1.minute

      post user_registration_path, params: signup_fields.merge(bot_trap_params(rendered_seconds_ago: stale))

      expect(response).to have_http_status(:unprocessable_content)
      expect(signup_exists?).to be(false)
    end

    # The max boundary from the accepting side: without this pin, shrinking
    # MAXIMUM_FORM_AGE (rejecting everyone whose form sat open over lunch)
    # would keep every spec green.
    it 'accepts a form left open just under the maximum age' do
      post user_registration_path,
           params: signup_fields.merge(
             bot_trap_params(rendered_seconds_ago: BotTrapProtected::MAXIMUM_FORM_AGE - 1.minute)
           )

      expect(signup_exists?).to be(true)
    end

    # The boundary in the other direction: exactly at the minimum is a pass, so
    # the check cannot quietly drift into rejecting normal submissions. Frozen
    # clock for the same reason as the too-fast case: wall time elapsing between
    # signing the token here and judging it in the controller would inflate the
    # age past the boundary and hide a drift into `age <= MINIMUM`.
    it 'accepts a submission at the minimum fill time' do
      travel_to(Time.current) do
        post user_registration_path,
             params: signup_fields.merge(
               bot_trap_params(rendered_seconds_ago: BotTrapProtected::MINIMUM_FILL_SECONDS)
             )
      end

      expect(signup_exists?).to be(true)
    end

    # The reject side of the minimum boundary (n-1): one second under must still
    # be rejected. The accept-side test pins exactly MINIMUM; without this, the
    # constant drifting down (3 -> 1) or the comparison loosening to `age < 1`
    # would let a faster-than-human submission through with every spec still green.
    it 'rejects a submission one second under the minimum fill time' do
      travel_to(Time.current) do
        post user_registration_path,
             params: signup_fields.merge(
               bot_trap_params(rendered_seconds_ago: BotTrapProtected::MINIMUM_FILL_SECONDS - 1)
             )
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(signup_exists?).to be(false)
    end
  end

  # A rejected submission must not cost the applicant what they typed —
  # otherwise a false positive means filling the whole form again.
  it 'keeps the entered name and address when re-rendering after a rejection' do
    post user_registration_path, params: signup_fields

    expect(response.body).to include('otto.neu@example.com')
    expect(response.body).to include('Otto')
  end

  # The invitation branch of bot_trap_reject reloads @invitation inside
  # without_tenant before re-rendering :new. That reload runs BEFORE the action,
  # outside the tenant block the :new template usually gets -- a scoping slip or
  # a template that needs the invitation would 500 here, not 422. No spec posted
  # an invitation token with a broken trap, so that path shipped unproven.
  it 'rejects an invited submission with a broken trap without crashing' do
    organisation = create(:organisation)
    invitation = ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: 'kollege@example.com')
    end

    # No timestamp param -> verdict :timestamp_missing -> bot_trap_reject.
    post user_registration_path,
         params: signup_fields.deep_merge(user: { email: 'kollege@example.com' }).merge(token: invitation.token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('flash.bot_trap.rejected'))
    expect(User.exists?(email: 'kollege@example.com')).to be(false)
  end
end
