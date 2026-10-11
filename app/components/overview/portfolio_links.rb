# frozen_string_literal: true

module Overview
  # Shared drill-down link builder for the portfolio widgets (org_stats_cards + billing_overview).
  # A clickable figure links to the "Zeiten" (time-tracking) list pre-filtered so the resulting
  # list reproduces exactly the number shown on the tile.
  #
  # CRITICAL: Overview::PortfolioStats has NO time window — its figures are org all-time totals. The
  # time-tracking page, however, defaults to date_range=this_month. So every drill-down MUST pin
  # date_range=all, otherwise the filtered list would not match the all-time figure on the widget.
  # This invariant lives here ONCE so the two widgets can't drift apart.
  #
  # Mixed into ViewComponents (which expose the route helpers and a private `organisation` reader).
  module PortfolioLinks
    # Billing statuses (TimeSession::BILLING_STATUS_FILTERS) aggregated by the org_stats "Ausstehend"
    # figure: loose + already-grouped, but not yet billed.
    UNBILLED_STATUS_KEYS = %w[without_billing in_billing].freeze

    private

    # Path to the time-tracking list filtered to the given billing status keys, pinned to all-time.
    # Routed through the `helpers` proxy: a ViewComponent's own scope exposes a wrong-arity stub for
    # nested path helpers, so we go through the view context that carries the real route helpers.
    def time_tracking_drilldown_path(status_keys)
      helpers.organisation_time_sessions_path(organisation, status_filters: Array(status_keys), date_range: 'all')
    end
  end
end
