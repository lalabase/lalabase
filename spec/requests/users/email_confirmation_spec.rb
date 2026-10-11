# frozen_string_literal: true

require 'rails_helper'

# E-mail confirmation on the signup surface (registration hardening).
#
# Before this, any invented address produced a working account plus its own
# organisation: nothing ever checked that the registrant could read the mailbox.
# :confirmable closes that, but ONLY if the four account-creating paths agree on
# who gets a mail — which is the point of this file:
#
#   self-registration  -> unconfirmed + exactly ONE mail, signed in anyway
#                         (grace period; the seeded onboarding must stay
#                         reachable, otherwise the signup flow loses its point)
#   invitation signup  -> confirmed instantly, NO mail (the token was already
#                         delivered to that very address)
#   invitation accept  -> same, via Actors::AcceptInvitation
#   admin-created user -> confirmed instantly, NO mail (Admin::User carries no
#                         Devise at all, so nothing would ever stamp it and the
#                         account would expire in silence)
#
# Plus the boundary that gives the grace period teeth: once it has elapsed the
# login is refused.
RSpec.describe 'E-mail confirmation', :ci_guard, type: :request do
  let(:valid_params) do
    {
      user: {
        first_name: 'Otto',
        last_name: 'Neuling',
        email: 'otto.neu@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        terms_accepted: '1'
      }
      # Trap params: mandatory on every real submission (BotTrapRequestHelpers).
    }.merge(bot_trap_params)
  end

  def created_user
    User.find_by(email: 'otto.neu@example.com')
  end

  # The system account is created lazily by the onboarding seed. Pre-creating it
  # keeps the delivery counts below about the registrant — and pins that its
  # own creation sends nothing (its reserved domain does not exist).
  before do
    expect { User.system }.not_to(change { ActionMailer::Base.deliveries.size })
    ActionMailer::Base.deliveries.clear
  end

  describe 'self-registration without a token' do
    it 'creates an unconfirmed account and sends exactly one confirmation mail' do
      expect { with_delivered_mails { post user_registration_path, params: valid_params } }
        .to change { ActionMailer::Base.deliveries.size }.by(1)

      user = created_user
      expect(user.confirmed?).to be(false)
      expect(user.confirmation_sent_at).to be_present

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq(['otto.neu@example.com'])
      expect(mail.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
    end

    it 'signs the new account in anyway — the grace period carries the onboarding' do
      with_delivered_mails { post user_registration_path, params: valid_params }

      # Following the redirect has to land inside the app, not back on a login
      # or confirmation wall.
      follow_redirect!
      expect(response).not_to redirect_to(new_user_session_path)
      expect(controller.current_user).to eq(created_user)
    end

    # Regression, signed-IN click: the grace period means the registrant is
    # signed in the moment they sign up, and load_tenant_from_session bounced
    # them to /select_organisation before the confirmation ever ran.
    it 'confirms the account when the mailed link is opened while still signed in' do
      with_delivered_mails { post user_registration_path, params: valid_params }
      user = created_user
      expect(controller.current_user).to eq(user)

      # The digest is stored, so read the raw token off the generated URL the
      # way the recipient would. .decoded, not .encoded: quoted-printable wraps
      # long lines with a soft "=\r\n" break, which lands INSIDE the token and
      # yields a truncated string that confirms nothing.
      raw_token = ActionMailer::Base.deliveries.last.body.decoded[/confirmation_token=([^"&\s]+)/, 1]
      expect(raw_token).to be_present

      get user_confirmation_path(confirmation_token: raw_token)

      expect(user.reload.confirmed?).to be(true)
      expect(user.confirmation_grace_days_left).to be_nil
    end

    # Regression, signed-OUT click — the common case, because the link is opened
    # wherever the mail is read. authenticate_user! covers every action but
    # 'new', so this used to redirect to the login page and confirm nothing.
    it 'confirms the account when the mailed link is opened without a session' do
      with_delivered_mails { post user_registration_path, params: valid_params }
      user = created_user
      raw_token = ActionMailer::Base.deliveries.last.body.decoded[/confirmation_token=([^"&\s]+)/, 1]

      delete destroy_user_session_path
      expect(controller.current_user).to be_nil

      get user_confirmation_path(confirmation_token: raw_token)

      expect(user.reload.confirmed?).to be(true)
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:notice]).to eq(I18n.t('devise.confirmations.confirmed'))
    end
  end

  describe 'signup through an invitation link' do
    let(:organisation) { create(:organisation) }
    let(:invitation) do
      ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'otto.neu@example.com')
      end
    end

    it 'confirms immediately and sends no confirmation mail' do
      expect { post user_registration_path, params: valid_params.merge(token: invitation.token) }
        .not_to(change { ActionMailer::Base.deliveries.size })

      expect(created_user.confirmed?).to be(true)
    end

    # The token proves ONE mailbox: the invited one. A form that sends another
    # address must not turn it into a confirmed account (it would carry the
    # submitter's password for a mailbox they never proved).
    it 'registers the invited address, not a different one typed into the form' do
      params = valid_params.deep_merge(user: { email: 'victim@corp.example' }).merge(token: invitation.token)

      expect { post user_registration_path, params: params }
        .not_to(change { ActionMailer::Base.deliveries.size })

      expect(User.find_by(email: 'victim@corp.example')).to be_nil
      expect(created_user).to be_present
      expect(created_user.confirmed?).to be(true)
    end

    it 'treats the invited address case-insensitively' do
      ActsAsTenant.with_tenant(organisation) do
        invitation.update!(email: 'Otto.Neu@Example.com')
      end

      post user_registration_path, params: valid_params.merge(token: invitation.token)

      expect(created_user.confirmed?).to be(true)
    end

    it 'still confirms nobody when the token is expired (falls back to the normal path)' do
      ActsAsTenant.with_tenant(organisation) do
        invitation.update!(sent_at: 10.days.ago)
      end

      expect { with_delivered_mails { post user_registration_path, params: valid_params.merge(token: invitation.token) } }
        .to change { ActionMailer::Base.deliveries.size }.by(1)

      expect(created_user.confirmed?).to be(false)
    end
  end

  describe 'invitation accepted through Actors::AcceptInvitation' do
    it 'confirms the freshly created invitee without a mail' do
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'invitee@example.com')
      end

      result = nil
      expect do
        # The membership it creates resolves the organisation's default role,
        # which is tenant-scoped — same context the real caller runs in.
        ActsAsTenant.with_tenant(organisation) do
          result = Actors::AcceptInvitation.call(
            invitation: invitation, password: 'password123', password_confirmation: 'password123',
            current_user: nil
          )
        end
      end.not_to(change { ActionMailer::Base.deliveries.size })

      expect(result).to be_success
      expect(User.find_by(email: 'invitee@example.com').confirmed?).to be(true)
    end
  end

  describe 'user created in the admin backend' do
    it 'counts as confirmed even though Admin::User has no Devise' do
      user = Admin::User.create!(
        email: 'admin.made@example.com', first_name: 'Ada', last_name: 'Admin',
        password: 'password123', active: true
      )

      expect(user.reload.confirmed_at).to be_present
      # Read back through the Devise-carrying class: this is the account that
      # has to survive the grace period.
      expect(User.find(user.id).confirmed?).to be(true)
    end
  end

  describe 'the grace period boundary' do
    let(:password) { 'password123' }
    # Both accounts need a membership: a user without one is bounced back to the
    # login by the app's own "no organisation" guard, which would mask whether
    # Devise accepted the credentials at all.
    let(:organisation) { create(:organisation) }

    def sign_in_with(user)
      post user_session_path, params: { user: { email: user.email, password: password } }
    end

    it 'lets an unconfirmed account in while the window is open' do
      user = create(:user, :unconfirmed, password: password, organisation: organisation)

      sign_in_with(user)

      expect(controller.current_user).to eq(user)
    end

    it 'refuses the login once the window has closed' do
      user = create(:user, :confirmation_overdue, password: password, organisation: organisation)

      sign_in_with(user)

      # Devise::FailureApp answers here, not a controller of ours — so the flash
      # and the bounce back to the login are what there is to assert.
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
    end

    # THE regression for this feature. Devise measures the window from
    # confirmation_sent_at, and the public resend endpoint rewrites that field
    # once confirm_within has elapsed (generate_confirmation_token: expired
    # token → new token AND sent_at = now). A never-confirmed account could
    # therefore buy three fresh days of full access every seven days, forever,
    # by posting a form — defeating the entire point. The override anchors the
    # window to created_at instead.
    it 'cannot buy more access by asking for a new confirmation mail' do
      user = create(:user, :confirmation_overdue, password: password, organisation: organisation)
      # Past confirm_within, so Devise issues a NEW token rather than reusing it.
      user.update_columns(confirmation_sent_at: (Devise.confirm_within + 1.day).ago)

      expect do
        with_delivered_mails { post user_confirmation_path, params: { user: { email: user.email } } }
      end.to change { ActionMailer::Base.deliveries.size }.by(1)

      # The mail went out (an expired link must not be a dead end) …
      expect(user.reload.confirmation_sent_at).to be > 1.minute.ago
      # … but it bought nothing.
      expect(user.confirmation_grace_days_left).to eq(0)

      sign_in_with(user)

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
    end
  end

  describe 'the reminder banner' do
    let(:organisation) { create(:organisation) }

    def visit_app_as(user)
      sign_in user
      get root_path
      follow_redirect! while response.redirect?
    end

    it 'shows the deadline and a resend button while the address is unproven' do
      user = create(:user, :unconfirmed, organisation: organisation)

      visit_app_as(user)

      expect(response.body).to include('data-testid="email-confirmation-banner"')
      expect(response.body).to include(I18n.t('views.layouts.email_confirmation.title'))
      expect(response.body).to include(I18n.t('views.layouts.email_confirmation.resend'))
    end

    it 'disappears once the address is confirmed' do
      user = create(:user, organisation: organisation)

      visit_app_as(user)

      expect(response.body).not_to include('data-testid="email-confirmation-banner"')
    end

    # Regression guard. The banner was `fixed top-0 left-0 right-0` at body
    # level, out of the document flow and — unlike _deletion_warning, which at
    # least carried an h-16 spacer — with NOTHING reserving its height. It
    # therefore lay on top of the first ~60px of every page. On a ticket that is
    # exactly the row carrying the time-tracking actions: a freshly registered
    # user could neither see nor click "start time session" in their own seeded
    # onboarding project.
    #
    # Two independent properties, because either one alone can be true while the
    # bug is back: it must live inside <main> (not at body level), and it must
    # not be taken out of the flow again.
    it 'sits inside the main column and in the document flow' do
      user = create(:user, :unconfirmed, organisation: organisation)

      visit_app_as(user)

      banner = Nokogiri::HTML(response.body).at_css('[data-testid="email-confirmation-banner"]')
      expect(banner).to be_present
      expect(banner.ancestors('main')).not_to be_empty
      expect(banner['class'].split).not_to include('fixed', 'absolute')
    end
  end

  describe 'an expired or wrong confirmation link' do
    # Devise renders :new (the resend form) instead of redirecting when the
    # token is invalid or past confirm_within — which, after seven days, is
    # every click from the original mail. Rendered in the app layout it served
    # an anonymous visitor the org sidebar.
    it 'renders the resend form without the signed-in application chrome' do
      get user_confirmation_path(confirmation_token: 'nope-not-a-real-token')

      # 200, not 422: respond_with_navigational runs the render block for a
      # navigational format and drops the status Devise passes alongside it.
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('devise.confirmations.new.title'))
      expect(response.body).not_to include('id="sidebar"')
    end
  end
end
