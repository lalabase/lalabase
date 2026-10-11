# frozen_string_literal: true

module Organisations
  # "Verbrauch" — the AI area's consumption page (doc/ki_bereich_navigation_plan.md S6,
  # gap L8).
  #
  # Three displays used to share the settings page with the package catalogue and the
  # provider form: the quota bar, the six-month Nachweis-Historie and the 30-day token
  # statistic. That is what made the hub's "Verbrauch" card link to the same URL as its
  # "Zugang" card — two questions, one page, one link.
  #
  # ORDER IS THE ARGUMENT HERE (L8): credits first, tokens last. Tokens are our
  # purchasing unit; credits are what the customer is measured against and what the gate
  # enforces. The six-month history is not decoration either — the Kontingent decision
  # makes it a Nachweis-Pflicht that has to exist before a hard gate may bite.
  class AiUsagesController < BaseController
    before_action :set_organisation
    before_action :authorize_ai_usage

    # The token statistic's window. Informational only (see the class comment), so it
    # deliberately does not follow the ledger's calendar month — it answers "was ist
    # zuletzt passiert", not "was wird abgerechnet".
    USAGE_STATS_DAYS = 30

    def show
      # ONE ledger for the whole request, handed to BOTH shared partials.
      # Lalabase::Llm::QuotaLedger memoises #used, #budget and #buffer per instance, and
      # this page asks all three several times over (bar, banners, percentage, history).
      # Left to themselves the two partials build one ledger each — that is a second
      # consumption SUM plus another pair of uncached SystemSetting.get reads for
      # numbers that cannot change within a render. The same reason QuotaLedger became
      # memoised in the first place (the hub paid eight of those for one card).
      @ledger = @organisation.ai_quota_ledger
      @usage_stats = @organisation.ai_usage_stats(USAGE_STATS_DAYS)
    end

    private

    # Membership-scoped lookup + tenant reset, verbatim the reasoning of
    # AiOverviewsController#set_organisation and AiSettingsController#set_organisation:
    # `current_user.organisations.find` raises RecordNotFound for a non-member (404, no
    # existence leak) instead of loading a foreign org, and the tenant has to be reset
    # because the policy checks account_admin? against ActsAsTenant.current_tenant —
    # leaving the session's org in place would let the check pass against the wrong
    # organisation.
    def set_organisation
      @organisation = current_user.organisations.find(params[:organisation_id])
      @current_organisation = @organisation
      ActsAsTenant.current_tenant = @organisation
    end

    def authorize_ai_usage
      authorize @organisation, :show?, policy_class: AiUsagePolicy
    end
  end
end
