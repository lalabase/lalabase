# frozen_string_literal: true

# app/controllers/users/confirmations_controller.rb
module Users
  # Every action here is reached WITHOUT a session in the normal case: the
  # confirmation link is opened wherever the mail is read, and the resend form
  # is for people who cannot get in. Devise's stock controller would render both
  # inside the full application chrome (sidebar, organisation switcher,
  # notification bell) that a signed-out visitor has no data for.
  class ConfirmationsController < Devise::ConfirmationsController
    # ALL actions, not just new/create. #show does not "only redirect": on an
    # invalid or EXPIRED token Devise renders :new instead
    # (devise/confirmations_controller.rb:31), and past confirm_within that is
    # every click from the original mail. Measured before the fix: a signed-out
    # GET with a stale token returned 200 carrying the org sidebar.
    layout 'application_auth'

    # load_tenant_from_session redirects a signed-IN user who has no
    # organisation in the session to /select_organisation — and during the grace
    # period the registrant IS signed in, so the click confirmed nothing and the
    # account would have expired on day four. Measured; the mutation kills a
    # spec. Same treatment Users::RegistrationsController and
    # Users::SessionsController give their session-less actions.
    #
    # NOT skipped: authenticate_user!. It looks necessary and is not — Devise
    # defines it as `warden.authenticate!(opts) if !devise_controller? ||
    # opts.delete(:force)` (devise-4.9.4, controllers/helpers.rb:120), i.e. a
    # no-op inside any Devise controller. A skip here would be dead code
    # claiming to guard the signed-out path.
    skip_before_action :load_tenant_from_session
  end
end
