# frozen_string_literal: true

# The one-time link that signs in a visitor the separate website just signed up
# (website split, step W2.4). The website cannot open a session in the core, so
# the provisioning response carries this link and the browser follows it. From
# the visitor's side nothing changed: they are signed in when they arrive, the
# way they were when the form still lived here.
#
# Minting and consuming live in ONE place on purpose. A minter and a consumer
# that disagree about purpose, lifetime or single use would each look correct on
# its own, and the disagreement would show as an endpoint that signs people in
# longer than anyone meant:
#   - a purpose-scoped signed id, so no other signed id of that user stands in,
#   - two minutes, because this is a redirect and not a session,
#   - good for an account that has never been seen, claimed atomically, so the
#     link works exactly once even when two clicks arrive together.
#
# Entry point: url_for (mint) and claim (consume).
module Signups
  class Handoff
    PURPOSE = :signup_handoff
    VALID_FOR = 2.minutes

    # The host is the one the confirmation mail uses: the link goes to the core's
    # public address, which is not the address the website called us on.
    #
    # ActionMailer::Base and not config.action_mailer.default_url_options:
    # measured under RSpec, the config object answers {} while ActionMailer::Base
    # carries the host. Reading the config would work in production and quietly
    # fall back to whatever the suite set on the routes in test, which is how a
    # link with the wrong host reaches customers with every spec green.
    def self.url_for(user:)
      Rails.application.routes.url_helpers.users_signup_handoff_url(
        token: user.signed_id(purpose: PURPOSE, expires_in: VALID_FOR),
        **ActionMailer::Base.default_url_options
      )
    end

    # Answers the user when THIS call consumed the link, and nil in every other
    # case: provisioning switched off, no token, a foreign or expired signature,
    # an account that may not sign in, or a link that was already used.
    def self.claim(token:)
      return unless Rails.configuration.x.provisioning.enabled?

      user = User.find_signed(token.to_s, purpose: PURPOSE)
      return unless user&.active_for_authentication?

      user if user.claim_first_visit!
    end
  end
end
