# frozen_string_literal: true

module Organisations
  # The historical entry point to the billing area, now a pure forwarder
  # (K3 of doc/konto_ebene_plan.md). The area itself moved one level up to
  # BillingAccountsController, where it belongs: it talks about the Account, not
  # about the organisation it used to hang below.
  #
  # KEPT rather than deleted because the route is live, bookmarked, carries the
  # N2 deep-link work and is the target of the "Rechnung" settings tab. There is
  # exactly ONE implementation after this: this controller renders nothing.
  #
  # What the forward deliberately does NOT fix: it still runs through
  # BaseController, so it still demands an active membership. That is fine, it is
  # only the shortcut out of an organisation now. N1 is solved because the owner
  # uses the account path directly, and that one asks for no membership.
  class BillingController < BaseController
    # This controller no longer authorizes anything -- it forwards, and the
    # target authorizes in full (AccountPolicy#show_overview? / #manage_billing?).
    # Denying here as well would only duplicate the rule in a place that cannot
    # be the one that decides.
    skip_after_action :verify_authorized

    def show
      redirect_to_account { |account| billing_account_path(account) }
    end

    def edit
      redirect_to_account { |account| edit_billing_account_path(account) }
    end

    private

    # E9b: organisations.account_id is still nullable, so an organisation without
    # an account has nowhere to forward TO. The production backfill (E9a) covers
    # today's data; this covers dev/test databases and every organisation created
    # through a path that skips the callback.
    def redirect_to_account
      account = @current_organisation.account
      return redirect_to(yield(account)) if account

      redirect_to organisation_root_path(@current_organisation),
                  alert: t('controllers.billing_accounts.missing_account')
    end
  end
end
