# frozen_string_literal: true

module Users
  # Opens the session for a visitor the separate website just signed up (website
  # split, step W2.4). The website has no database and cannot write a session
  # here, so it hands the browser a one-time link instead. Every rule about that
  # link belongs to Signups::Handoff; this controller decides what the visitor
  # sees.
  class SignupHandoffsController < ApplicationController
    # Not a Devise controller, so the app-wide authenticate_user! would send the
    # brand-new visitor to the sign-in page before their link was ever read.
    skip_before_action :authenticate_user!

    # Reached without a session in the normal case. For the exception, somebody
    # who is already signed in, load_tenant_from_session would answer first and
    # send them to the organisation picker: measured, and it takes the decision
    # below out of this controller's hands. Same treatment the confirmations
    # controller gives its session-less action.
    skip_before_action :load_tenant_from_session

    # Rails runs this GET action for a HEAD request too, and running it CONSUMES
    # the link: measured, a single HEAD claimed the first visit and the
    # customer's own click then found the link used. Nothing legitimate follows
    # a sign-in link with HEAD, so it is refused instead of spent.
    before_action :refuse_head

    def show
      # An existing session wins. Swapping it for another account behind a link
      # in a URL is a surprise nobody asked for, and the link stays unused.
      return redirect_to after_sign_in_path_for(current_user) if user_signed_in?

      user = Signups::Handoff.claim(token: params[:token])
      return refuse unless user

      sign_in(user)
      redirect_to after_sign_in_path_for(user), notice: arrival_notice(user)
    end

    private

    # The same greeting the form used to show, so the arrival reads the same --
    # plus, for somebody who asked for the new-founder discount, the one sentence
    # that tells them what they actually have: a request and a phone call, NOT
    # an active discount. The core's own form said this until the founder block
    # left it on 20.09.2026; this link is where every customer of ours arrives,
    # and until 21.09.2026 it answered five typed-in details with a plain welcome.
    def arrival_notice(user)
      greeting = t('devise.registrations.signed_up')
      return greeting unless founder_request_open?(user)

      [greeting, t('flash.registrations.founder_signup_received')].join(' ')
    end

    # Open, not merely present: a request somebody already decided has been
    # answered by phone, and "we will call you" would be wrong for it. The link
    # only exists for the two minutes after a sign-up, so in practice this is the
    # request that sign-up just made.
    def founder_request_open?(user)
      FounderSignup.where(status: FounderSignup::STATUS_OPEN)
                   .exists?(account_id: user.organisations.select(:account_id))
    end

    def refuse_head
      head :method_not_allowed if request.head?
    end

    # One answer for every failure: expired, already used, wrong purpose, made
    # up, or provisioning switched off. Telling them apart would only help
    # somebody who is guessing.
    def refuse
      redirect_to new_user_session_path, alert: t('flash.signup_handoffs.invalid')
    end
  end
end
